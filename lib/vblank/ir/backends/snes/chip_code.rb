# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # A GAME'S ROUTINES AS SUPER FX CODE: the routines marked `on_chip: true`, on a cartridge with
        # that chip. It walks the IR with a table for each kind, as Lowering does, and writes the
        # chip's instructions through SNES::GSU. What the chip is, and how it is handed a program,
        # are in GSU and Runtime::Chip; Lowering::Chip is the part on the 65816's side.
        #
        # WHERE THE NUMBERS ARE. The chip cannot reach the console's work RAM, so the variables a run
        # needs are copied into the chip's own RAM before it starts and the ones it changed are
        # copied back after it stops. No game number lives there between runs. The block is in the
        # part of that RAM a painted screen does not use (Runtime::ChipPaint::NUMBERS): variables,
        # then what the code keeps for itself, a loop's count and a routine's way back.
        #
        # HOW A NUMBER IS WORKED OUT. A game's number is 32 bits and the chip's registers are 16, so
        # a value leaves its answer in two registers, LOW and HIGH. A sum of two has the right side
        # in RIGHT_LOW and RIGHT_HIGH. A side that is a number or a variable is read straight there;
        # when both sides have to be worked out, the right one goes to a word of RAM while the left
        # one is. Nothing stays in a register from one statement to the next. Other sums are called
        # (Runtime::ChipSums, which says how).
        #
        # A CALL IS LINK AND A JUMP, and a routine that calls keeps its return address in a word of its
        # own. So a routine cannot call itself, and a program in which one can is refused before
        # this is reached (LoweringPlan#refuse_routines_that_call_themselves!).
        #
        # ALL OF IT IS ONE SECTION, so it is all in one bank of the cartridge. The chip jumps with
        # 16-bit addresses inside a bank, and its quick memory takes no notice of which bank a byte
        # is from.
        #
        # A BRANCH REACHES ONLY 127 BYTES. A jump to anywhere is an IWT into R15. Written out
        # everywhere that would be longer and slower for the many that do not need it, and how far a
        # branch must go is not known until what it jumps over has been written. So everything is
        # written with short branches, those that turn out too short are noted, and it is all
        # written again with those as long jumps, until none is left.
        class ChipCode
          Sums = Runtime::ChipSums
          LOW = Sums::LOW
          HIGH = Sums::HIGH
          RIGHT_LOW = Sums::RIGHT_LOW
          RIGHT_HIGH = Sums::RIGHT_HIGH

          STATEMENTS = Ractor.make_shareable({ set: :emit_set, add: :emit_add, sub: :emit_sub, copy: :emit_copy, if: :emit_if,
                                               repeat: :emit_repeat, call: :emit_call, negate: :emit_negate,
                                               abs: :emit_abs, negate_abs: :emit_negate_abs, clamp: :emit_clamp,
                                               list_set: :emit_list_set, list_push: :emit_list_push,
                                               list_drop: :emit_list_drop, list_fill: :emit_list_fill,
                                               list_copy: :emit_list_copy })
          VALUES = Ractor.make_shareable({ int: :value_of_int, var_ref: :value_of_var_ref, binop: :value_of_binop,
                                           neg: :value_of_neg, absolute: :value_of_absolute, clamped: :value_of_clamped,
                                           mul_fix: :value_of_mul_fix, div_fix: :value_of_div_fix,
                                           shift_right: :value_of_shift_right, table_get: :value_of_table_get,
                                           list_get: :value_of_list_get, list_len: :value_of_list_len })

          # The sums called rather than written in place. A routine that makes any of them, and so
          # uses LINK, keeps its own return address safe first.
          CALLED_SUMS = Ractor.make_shareable({ :* => Sums::MULTIPLY, :/ => Sums::DIVIDE, :% => Sums::REMAINDER,
                                                :<< => Sums::SHIFT_LEFT, :>> => Sums::SHIFT_RIGHT })
          # The kinds that call a routine, or can: a call, a sum with fractions, and a shift a step at
          # a time past what is written in place.
          CALLING_KINDS = %i[call mul_fix div_fix shift_right].freeze

          # A table the chip reads: the label of its entries, how many it has, and how each is kept
          # (bytes, and whether it has a sign).
          TableRead = Data.define(:label, :count, :bytes, :signed)
          # A list the chip reads and writes: its 16-bit place in the chip's RAM (its header, then its
          # slots, as Runtime::Lists lays them out), how many bytes a slot takes, and whether the
          # game takes items from its front anywhere, which makes its slots a ring.
          ListPlace = Data.define(:at, :width, :ring)
          # A way a run can stop the game on a list, at +label+: an index outside it (the index in
          # the registers +low+ and +high+), an item added to it when full, or one taken from it when
          # empty (+from_front+ saying which end).
          ListFault = Data.define(:label, :list, :kind, :low, :high, :from_front)
          # The number the chip leaves for each kind of fault, for Lowering::Chip#emit_chip_fault_check.
          FAULT_KINDS = Ractor.make_shareable({ index: 0, full: 1, empty: 2 })
          # The list steps that can stop the game, and of those the ones that are not an index.
          FAULTING_LIST_KINDS = %i[list_get list_set list_push list_drop list_fill].freeze
          ENDS_LIST_KINDS = %i[list_push list_drop].freeze
          Lists = Runtime::Lists
          IN_PLACE_SUMS = Ractor.make_shareable({ :+ => %i[add adc], :- => %i[sub sbc], :& => %i[and_ and_], :| => %i[or_ or_],
                                                  :^ => %i[xor xor] })
          COMPARISONS = %i[< <= > >= == !=].freeze
          # Which branch is taken when a comparison does NOT hold, for each comparison.
          FAILS = Ractor.make_shareable({ :== => :bne, :!= => :beq, :< => :bge, :> => :bge, :>= => :blt, :<= => :blt })
          OPPOSITE = Ractor.make_shareable({ bne: :beq, beq: :bne, bge: :blt, blt: :bge, bpl: :bmi, bmi: :bpl, bcc: :bcs,
                                             bcs: :bcc })
          WRITTEN_AS_STATEMENTS = %i[set add sub negate abs negate_abs clamp].freeze

          # The 16-bit addresses the chip uses for the block of numbers in its RAM.
          FIRST_NUMBER = Runtime::ChipPaint::NUMBERS - Runtime::ChipPaint::COPY
          NUMBERS_END = Runtime::ChipPaint::NUMBERS_END - Runtime::ChipPaint::COPY

          # A shift by a number written in the program is written in place up to this many steps
          # past a whole half: four bytes a step, against the call's seven.
          MOST_WRITTEN_STEPS = 4
          # How many bytes one short branch reaches, forward, from the byte after it.
          BRANCH_REACH = (-128..127)

          # +routines+ is the names of every routine to make, and +funcs+ the IR of each. +plan+
          # folds what is written in the program (LoweringPlan), and +holds+ says what the section
          # is to the author, for a cartridge too full for it. +tables+ is a TableRead for each table
          # by name, +lists+ a ListPlace for each list the chip reaches, and +numbers_end+ where the
          # block of numbers stops, the lists being past it.
          def initialize(routines:, funcs:, plan:, holds:, tables: {}, lists: {}, numbers_end: NUMBERS_END)
            @routines = routines
            @funcs = funcs
            @plan = plan
            @holds = holds
            @tables = tables
            @lists = lists
            @numbers_end = numbers_end
            @places = {} # a name, or [what, a statement's identity], -> its word in the chip's RAM
            @next_place = FIRST_NUMBER
            @far_branches = {} # a branch's number, for each that a short branch cannot reach
            @routines.each { |name| named_in(routines_from(name)).each { |variable| place_of(variable) } }
            return unless @routines.any? { |name| faults?(name) }

            place_of(:fault_list, bytes: 2)
            place_of(:fault_index)
            place_of(:fault_kind, bytes: 2) if @routines.any? { |name| faults_at_ends?(name) }
          end

          # Whether a run of +name+ can stop the game: a list read or written at an index outside it,
          # an item added to a full one or taken from an empty one.
          def faults?(name) = statements_of(routines_from(name)).any? { |node| FAULTING_LIST_KINDS.include?(node.kind) }

          # Whether it can stop the game the second way or the third, so the console has to ask which.
          def faults_at_ends?(name) = statements_of(routines_from(name)).any? { |node| ENDS_LIST_KINDS.include?(node.kind) }

          # Where the chip leaves which kind of fault it was (FAULT_KINDS).
          def fault_kind_place = place_of(:fault_kind, bytes: 2)

          # Where the chip leaves, on such a fault, the list's place (nought when there was none) and
          # the index, for the console to stop the game with (Lowering::Chip#emit_chip_run).
          def fault_list_place = place_of(:fault_list)
          def fault_index_place = place_of(:fault_index)

          # Where a run of +name+ starts.
          def self.entry_label(name) = "chip start #{name}"

          def self.routine_label(name) = "chip routine #{name}"

          # The variables a run of the routine +name+ reads or writes, each with its word in the
          # chip's RAM: a variable it writes only sometimes keeps its number the other times, so
          # those go across too.
          def variables_sent(name) = named_in(routines_from(name)).map { |variable| [variable, place_of(variable)] }

          # The ones it can change, to bring back.
          def variables_changed(name) = written_in(routines_from(name)).map { |variable| [variable, place_of(variable)] }

          # All of the chip's code, ready for the Linker.
          def section
            loop do
              lowered = lower_all
              reachless = @short_branches.reject { |_, from, label| BRANCH_REACH.cover?(lowered.labels.fetch(label) - from) }
              return lowered if reachless.empty?

              reachless.each { |number, _, _| @far_branches[number] = true }
            end
          end

          private

          # --- what a routine touches ---

          def routines_from(start)
            found = []
            waiting = [start]
            until waiting.empty?
              name = waiting.shift
              next if found.include?(name)

              found << name
              waiting.concat(Reach.routines_named(Reach.statements_under(@funcs.fetch(name))))
            end
            found
          end

          def statements_of(names) = names.flat_map { |name| Reach.statements_under(@funcs.fetch(name)) }

          def named_in(names)
            statements_of(names).flat_map { |node| Reach::VARIABLES_OF[node.kind]&.call(node) || [] }.uniq
          end

          def written_in(names)
            statements_of(names).filter_map do |node|
              case node.kind
              when *WRITTEN_AS_STATEMENTS then node.var
              when :copy then node.dest
              when :repeat then node.index
              end
            end.uniq
          end

          def uses_link?(name)
            Reach.statements_under(@funcs.fetch(name)).any? do |node|
              CALLING_KINDS.include?(node.kind) || (node.kind == :binop && CALLED_SUMS.key?(node.op))
            end
          end

          # --- the chip's RAM ---

          # The word of the chip's RAM for +key+, 4 bytes unless it says.
          def place_of(key, bytes: 4)
            @places.fetch(key) do
              if @next_place + bytes > @numbers_end
                raise LoweringError, "The routines marked on_chip: true use more numbers than the Super FX chip can " \
                                     "hold beside their lists. The chip holds #{(@numbers_end - FIRST_NUMBER) / 4} " \
                                     "numbers. To fix this, use fewer variables in those routines, fewer sums inside " \
                                     "sums, or smaller lists."
              end
              @places[key] = @next_place
              @next_place += bytes
              @places[key]
            end
          end

          def local_place(node, what) = place_of([what, node.object_id])

          # A word to keep a number in while another is worked out, by how deep the sum goes.
          def kept_place(depth) = place_of([:kept, depth])

          # --- the program ---

          def lower_all
            @gsu = GSU.new("chip program", holds: @holds)
            @labels = 0
            @branches = 0
            @short_branches = []
            @sums_called = []
            @depth = 0
            @routines.each { |name| emit_entry(name) }
            @routines.each { |name| emit_routine(name) }
            Sums.emit(@gsu, @sums_called, back: place_of(:sum_back, bytes: 2), kept: place_of(:sum_kept, bytes: 2))
            @gsu.section
          end

          # Where the console starts the chip: the routine, and STOP.
          def emit_entry(name)
            @gsu.label(self.class.entry_label(name))
            emit_call_of(self.class.routine_label(name))
            @gsu.stop
          end

          def emit_routine(name)
            keeps_link = uses_link?(name)
            back = place_of([:back, name], bytes: 2)
            @gsu.label(self.class.routine_label(name))
            @gsu.sm(back, 11) if keeps_link
            @outside_lists = []
            @funcs.fetch(name).children.each { |child| statement(child) }
            @gsu.lm(11, back) if keeps_link
            @gsu.jmp(11)
            @gsu.nop
            @outside_lists.each { |fault| emit_list_fault(fault) }
          end

          # A LIST THAT STOPS THE GAME — an index outside it, an item added when it is full or taken
          # when it is empty — and the chip cannot stop it: the console does, in Runtime::Lists's
          # words. So the chip leaves the list's place, the index (or which end an item was taken
          # from), and which kind of fault it was where the console looks after every run, and stops
          # where it stands, however deep in its calls.
          def emit_list_fault(fault)
            @gsu.label(fault.label)
            if fault.kind == :index
              @gsu.sm(fault_index_place, fault.low)
              @gsu.sm(fault_index_place + 2, fault.high)
            elsif fault.kind == :empty
              @gsu.ibt(0, fault.from_front ? 1 : 0)
              @gsu.sm(fault_index_place, 0)
              @gsu.ibt(0, 0)
              @gsu.sm(fault_index_place + 2, 0)
            end
            if @places.key?(:fault_kind)
              @gsu.ibt(0, FAULT_KINDS.fetch(fault.kind))
              @gsu.sm(fault_kind_place, 0)
            end
            @gsu.iwt(0, fault.list.at)
            @gsu.sm(fault_list_place, 0)
            @gsu.stop
          end

          def fresh(what)
            @labels += 1
            "chip #{what}##{@labels}"
          end

          # R11 at the instruction after the jump, and the jump. The NOP is the byte the chip has
          # already fetched, and LINK counts it.
          def emit_call_of(label)
            @gsu.link(4)
            @gsu.iwt(15, label)
            @gsu.nop
          end

          def emit_called_sum(label)
            @sums_called |= [label]
            emit_call_of(label)
          end

          # A branch to +label+ on a condition, or anywhere with :bra, and the NOP after it. Numbered
          # so a branch that reached too little on the last writing can go a long way on this one.
          def emit_branch(condition, label)
            number = (@branches += 1)
            return emit_far_branch(condition, label) if @far_branches[number]

            @gsu.public_send(condition, label)
            @short_branches << [number, @gsu.here, label]
            @gsu.nop
          end

          def emit_far_branch(condition, label)
            over = fresh("over")
            unless condition == :bra
              @gsu.public_send(OPPOSITE.fetch(condition), over)
              @gsu.nop
            end
            @gsu.iwt(15, label)
            @gsu.nop
            @gsu.label(over)
          end

          # --- statements ---

          def statement(node)
            return if Nodes.of_role(:declaration).include?(node.kind)

            send(STATEMENTS.fetch(node.kind), node)
          end

          def store(name, low: LOW, high: HIGH)
            at = place_of(name)
            @gsu.sm(at, low)
            @gsu.sm(at + 2, high)
          end

          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            value(node.value)
            store(node.var)
          end

          def emit_add(node)
            value(Build.binop(:+, Build.var_ref(node.var), node.operand))
            store(node.var)
          end

          def emit_sub(node)
            value(Build.binop(:-, Build.var_ref(node.var), node.operand))
            store(node.var)
          end

          def emit_copy(node)
            return if node.dest == node.src

            value(node.src)
            store(node.dest)
          end

          def emit_if(node)
            body = node.children
            otherwise = node.else&.children || []
            known = @plan.folded(node.cond)
            return (known.zero? ? otherwise : body).each { |child| statement(child) } if known

            other = fresh("else")
            done = fresh("end_if")
            jump_unless(node.cond, other)
            body.each { |child| statement(child) }
            emit_branch(:bra, done) unless otherwise.empty?
            @gsu.label(other)
            otherwise.each { |child| statement(child) }
            @gsu.label(done)
          end

          # Reference#exec_repeat: the count worked out once, the index counting 0, 1, 2... and stored
          # in the game's variable at the top of each pass, and +stop_when+ asked BEFORE the body.
          #
          # CACHE before the top keeps the first 512 bytes from here in the chip's quick memory, where
          # a byte takes a fifth of the time it takes from the ROM. It only costs the once: a loop that
          # starts it is a loop that goes round.
          def emit_repeat(node)
            count = local_place(node, :count)
            index = local_place(node, :index)
            value(node.count)
            @gsu.sm(count, LOW)
            @gsu.sm(count + 2, HIGH)
            @gsu.ibt(LOW, 0)
            @gsu.sm(index, LOW)
            @gsu.sm(index + 2, LOW)
            top = fresh("repeat")
            done = fresh("end_repeat")
            @gsu.cache
            @gsu.label(top)
            load_place(index, LOW, HIGH)
            load_place(count, RIGHT_LOW, RIGHT_HIGH)
            emit_flags_of_less(LOW, HIGH, RIGHT_LOW, RIGHT_HIGH)
            emit_branch(:bge, done)
            store(node.index) if node.index
            jump_if(node.stop_when, done)
            node.children.each { |child| statement(child) }
            load_place(index, LOW, HIGH)
            emit_add_small(1)
            @gsu.sm(index, LOW)
            @gsu.sm(index + 2, HIGH)
            emit_branch(:bra, top)
            @gsu.label(done)
          end

          def emit_call(node) = emit_call_of(self.class.routine_label(node.target))

          # A variable changed in place: turned round, made its size, made its size below nought
          # (Reference#exec_negate_abs: turned only when it is above nought), or held between two.
          def emit_negate(node) = value(Build.neg(Build.var_ref(node.var))).then { store(node.var) }
          def emit_abs(node) = value(Build.absolute(Build.var_ref(node.var))).then { store(node.var) }

          def emit_negate_abs(node)
            below = fresh("below_nought")
            load_variable(node.var, LOW, HIGH)
            @gsu.moves(0, HIGH)
            emit_branch(:bmi, below)
            Sums.emit_negate(@gsu, LOW, HIGH)
            @gsu.label(below)
            store(node.var)
          end

          def emit_clamp(node)
            value(Build.clamped(Build.var_ref(node.var), node.min, node.max))
            store(node.var)
          end

          # --- lists ---
          #
          # A list the chip reaches lives in the chip's own RAM for good (Lowering::Chip), so the
          # console's code reads and writes it there too, by its long address, and nothing is copied
          # for a run. The chip keeps it the way Runtime::Lists lays it out, so either processor can
          # change it and the other sees the same bytes: the header's capacity, where the first item
          # is and the length, then the slots.
          #
          # A list nothing takes from the front keeps its first item in its first slot for good, so
          # an item's slot is its index. One the game shifts anywhere, on either processor, goes round
          # its slots like a ring: an item's slot is its index counted on from the first item's, once
          # round to the start when that runs past the last slot. Only such a list pays for the sum.

          # Reference#exec_list_set: the index worked out, then the value, then the test.
          def emit_list_set(node)
            list = @lists.fetch(node.name)
            if plain?(node.index)
              value(node.value)
              load_plain(node.index, RIGHT_LOW, RIGHT_HIGH)
            else
              value(node.index)
              kept = kept_place(@depth)
              @gsu.sm(kept, LOW)
              @gsu.sm(kept + 2, HIGH)
              @depth += 1
              value(node.value)
              @depth -= 1
              load_place(kept, RIGHT_LOW, RIGHT_HIGH)
            end
            emit_slot_place(node.name, list, RIGHT_LOW, RIGHT_HIGH)
            emit_write_slot(list)
          end

          # The register a slot's place in the chip's RAM is worked out in.
          SLOT = 4
          # The register the fill counts its items down in.
          ITEMS_LEFT = 6

          # The number in LOW and HIGH into the slot at SLOT, as many bytes as the slot takes: a
          # narrow slot keeps the low bits (Reference::ListValue#wrap_to_width). SLOT is left two
          # bytes on for a whole word.
          def emit_write_slot(list)
            @gsu.from(LOW)
            return @gsu.stb(SLOT) if list.width == 1

            @gsu.stw(SLOT)
            return unless list.width == 4

            @gsu.inc(SLOT)
            @gsu.inc(SLOT)
            @gsu.from(HIGH)
            @gsu.stw(SLOT)
          end

          # Reference#exec_list_push: a full list stops the game before the value is worked out.
          # The value goes in the slot after the last item, and the length is one more.
          def emit_list_push(node)
            list = @lists.fetch(node.name)
            full = fresh("full #{node.name}")
            @outside_lists << ListFault.new(label: full, list: list, kind: :full, low: nil, high: nil, from_front: nil)
            @gsu.lm(SLOT, list.at + Lists::LENGTH)
            @gsu.lm(0, list.at + Lists::CAPACITY)
            @gsu.from(SLOT)
            @gsu.cmp(0)
            emit_branch(:bcs, full)
            value(node.value)
            @gsu.lm(SLOT, list.at + Lists::LENGTH)
            emit_slot_of_position(list)
            emit_write_slot(list)
            @gsu.lm(0, list.at + Lists::LENGTH)
            @gsu.inc(0)
            @gsu.sm(list.at + Lists::LENGTH, 0)
          end

          # Reference#exec_list_drop: an empty list stops the game. Taken from the back, the length is
          # one less. Taken from the front, the first item is the next slot round as well, back to the
          # first slot past the last, as Runtime::Lists's rt_list_drop has it.
          def emit_list_drop(node)
            list = @lists.fetch(node.name)
            front = node.from == :front
            empty = fresh("empty #{node.name}")
            @outside_lists << ListFault.new(label: empty, list: list, kind: :empty, low: nil, high: nil, from_front: front)
            @gsu.lm(SLOT, list.at + Lists::LENGTH)
            @gsu.moves(SLOT, SLOT)
            emit_branch(:beq, empty)
            @gsu.dec(SLOT)
            @gsu.sm(list.at + Lists::LENGTH, SLOT)
            return unless front

            kept = fresh("front_kept")
            @gsu.lm(SLOT, list.at + Lists::FRONT)
            @gsu.inc(SLOT)
            @gsu.lm(0, list.at + Lists::CAPACITY)
            @gsu.from(SLOT)
            @gsu.cmp(0)
            emit_branch(:bcc, kept)
            @gsu.ibt(SLOT, 0)
            @gsu.label(kept)
            @gsu.sm(list.at + Lists::FRONT, SLOT)
          end

          # Reference#exec_list_fill: the count worked out first, and nothing more done when it is
          # nought or below; then the first index, the first and the last item checked, as list_set
          # checks an index, and only then the value. A list the game shifts is never filled
          # (Builder#refuse_filled_shifted_lists!), so its run of items is a run of slots, written one
          # after another from the first.
          def emit_list_fill(node)
            list = @lists.fetch(node.name)
            done = fresh("filled")
            count = local_place(node, :count)
            from = local_place(node, :from)
            value(node.count)
            store_place(count)
            @gsu.moves(0, HIGH)
            emit_branch(:bmi, done)
            emit_nought_flag(LOW, HIGH)
            emit_branch(:beq, done)
            value(node.from)
            store_place(from)
            emit_slot_place(node.name, list, LOW, HIGH)
            emit_last_of_run(from, count)
            emit_slot_place(node.name, list, LOW, HIGH)
            value(node.value)
            @gsu.lm(SLOT, from)
            emit_slot_of_position(list)
            @gsu.lm(ITEMS_LEFT, count)
            item = fresh("fill_item")
            @gsu.label(item)
            emit_write_slot(list)
            (list.width == 1 ? 1 : 2).times { @gsu.inc(SLOT) }
            @gsu.dec(ITEMS_LEFT)
            emit_branch(:bne, item)
            @gsu.label(done)
          end

          # Reference#exec_list_copy: the start held so the whole run is inside the table, then the
          # list made to hold exactly the run, from its first slot. The table and the list keep an
          # entry the same way (Builder#refuse_mismatched_table_copy!), so the run's bytes go across
          # as they are, a byte at a time from the cartridge, and a narrow slot reads back with its
          # sign as any other does (#value_of_list_get). Nothing here can stop the game: the build
          # already held the count to the list's capacity and the table's length.
          #
          # The cartridge is read as #value_of_table_get reads it: writing R14 starts the read of
          # the byte there, GETB takes it, and an INC of R14 starts the next one.
          def emit_list_copy(node)
            list = @lists.fetch(node.name)
            table = @tables.fetch(node.table)
            value(Build.clamped(node.at, Build.int(0), Build.int(table.count - node.count)))
            (table.bytes.bit_length - 1).times do
              @gsu.with(LOW)
              @gsu.add(LOW)
            end
            @gsu.ibt_bank_of(0, table.label)
            @gsu.romb
            @gsu.iwt(0, table.label)
            @gsu.from(0)
            @gsu.to(14)
            @gsu.add(LOW)
            @gsu.iwt(SLOT, list.at + Lists::HEADER)
            @gsu.iwt(ITEMS_LEFT, node.count * table.bytes)
            byte = fresh("copy_byte")
            @gsu.label(byte)
            @gsu.to(0)
            @gsu.getb
            @gsu.inc(14)
            @gsu.from(0)
            @gsu.stb(SLOT)
            @gsu.inc(SLOT)
            @gsu.dec(ITEMS_LEFT)
            emit_branch(:bne, byte)
            @gsu.ibt(0, 0)
            @gsu.sm(list.at + Lists::FRONT, 0)
            @gsu.iwt(0, node.count)
            @gsu.sm(list.at + Lists::LENGTH, 0)
          end

          # LOW and HIGH at the run's last index, from + count - 1. Adding a word of every bit set is
          # taking one away.
          def emit_last_of_run(from, count)
            load_place(from, LOW, HIGH)
            load_place(count, RIGHT_LOW, RIGHT_HIGH)
            @gsu.with(LOW)
            @gsu.add(RIGHT_LOW)
            @gsu.with(HIGH)
            @gsu.adc(RIGHT_HIGH)
            @gsu.ibt(0, -1)
            @gsu.with(LOW)
            @gsu.add(0)
            @gsu.with(HIGH)
            @gsu.adc(0)
          end

          def store_place(at, low: LOW, high: HIGH)
            @gsu.sm(at, low)
            @gsu.sm(at + 2, high)
          end

          def value_of_list_get(node)
            list = @lists.fetch(node.name)
            value(node.index)
            emit_slot_place(node.name, list, LOW, HIGH)
            @gsu.to(LOW)
            return @gsu.ldb(SLOT).then { emit_widened(1) } if list.width == 1
            return @gsu.ldw(SLOT).then { emit_widened(2) } if list.width == 2

            @gsu.ldw(SLOT)
            @gsu.inc(SLOT)
            @gsu.inc(SLOT)
            @gsu.to(HIGH)
            @gsu.ldw(SLOT)
          end

          def value_of_list_len(node)
            @gsu.lm(LOW, @lists.fetch(node.name).at + Lists::LENGTH)
            @gsu.ibt(HIGH, 0)
          end

          # SLOT at the slot of +list+ the index in +low+ and +high+ names. An index below nought or
          # not below the list's length goes to the fault, which never comes back.
          def emit_slot_place(name, list, low, high)
            outside = fresh("outside #{name}")
            @outside_lists << ListFault.new(label: outside, list: list, kind: :index, low: low, high: high, from_front: nil)
            @gsu.moves(0, high)
            emit_branch(:bne, outside)
            @gsu.lm(SLOT, list.at + Lists::LENGTH)
            @gsu.from(low)
            @gsu.cmp(SLOT)
            emit_branch(:bcs, outside)
            @gsu.move(SLOT, low)
            emit_slot_of_position(list)
          end

          # SLOT, holding how many items past the first an item is, made the place of its slot.
          def emit_slot_of_position(list)
            emit_ring_wrap(list) if list.ring
            (list.width.bit_length - 1).times do
              @gsu.with(SLOT)
              @gsu.add(SLOT)
            end
            @gsu.iwt(0, list.at + Lists::HEADER)
            @gsu.with(SLOT)
            @gsu.add(0)
          end

          # SLOT counted on from the slot of the first item, and once round to the start when that
          # passes the last slot, as Runtime::Lists's rt_list_slot_of_a does it.
          def emit_ring_wrap(list)
            inside = fresh("in_ring")
            @gsu.lm(0, list.at + Lists::FRONT)
            @gsu.with(SLOT)
            @gsu.add(0)
            @gsu.lm(0, list.at + Lists::CAPACITY)
            @gsu.from(SLOT)
            @gsu.cmp(0)
            emit_branch(:bcc, inside)
            @gsu.with(SLOT)
            @gsu.sub(0)
            @gsu.label(inside)
          end

          # LOW holding a slot or an entry of +bytes+ bytes, which reads back with its top bit as the
          # sign (Reference::ListValue#wrap_to_width), made a whole number in LOW and HIGH.
          def emit_widened(bytes)
            if bytes == 1
              @gsu.with(LOW)
              @gsu.sex
            else
              @gsu.moves(LOW, LOW)
            end
            emit_high_of_sign
          end

          # HIGH nought, or every bit set when the flags say LOW is below nought. IBT sets no flags.
          def emit_high_of_sign
            above = fresh("sign_above")
            @gsu.ibt(HIGH, 0)
            emit_branch(:bpl, above)
            @gsu.dec(HIGH)
            @gsu.label(above)
          end

          # --- tables ---

          # Reference#value_of_table_get: the index made safe (LoweringPlan.index_kept_in_range), and
          # the entry read from the cartridge.
          #
          # THE CHIP READS THE CARTRIDGE ITSELF, through a buffer: ROMB says the bank, and writing
          # R14 starts the read of the byte at that address, which GETB then takes (waiting for it if
          # it has not come yet). Each GETB gets one byte, and an INC of R14 starts the next. A
          # table is in one bank, as every section is, so its bank is a number the linker knows.
          def value_of_table_get(node)
            table = @tables.fetch(node.name)
            value(LoweringPlan.index_kept_in_range(node.index, table.count))
            (table.bytes.bit_length - 1).times do
              @gsu.with(LOW)
              @gsu.add(LOW)
            end
            @gsu.ibt_bank_of(0, table.label)
            @gsu.romb
            @gsu.iwt(0, table.label)
            @gsu.from(0)
            @gsu.to(14)
            @gsu.add(LOW)
            emit_entry_read(table)
          end

          def emit_entry_read(table)
            if table.bytes == 1
              @gsu.to(LOW)
              return table.signed ? @gsu.getbs.then { emit_widened(2) } : @gsu.getb.then { @gsu.ibt(HIGH, 0) }
            end

            emit_word_read(LOW)
            return (table.signed ? emit_widened(2) : @gsu.ibt(HIGH, 0)) if table.bytes == 2

            @gsu.inc(14)
            emit_word_read(HIGH)
          end

          # Two bytes from where R14 is, into +register+, R14 left at the second.
          def emit_word_read(register)
            @gsu.to(register)
            @gsu.getb
            @gsu.inc(14)
            @gsu.with(register)
            @gsu.getbh
          end

          # --- one-sided sums ---

          def value_of_neg(node)
            value(node.operand)
            Sums.emit_negate(@gsu, LOW, HIGH)
          end

          def value_of_absolute(node)
            value(node.operand)
            Sums.emit_size_of(@gsu, LOW, HIGH, fresh("size"))
          end

          # Reference#clamp_value: held at the floor first and the ceiling second, so a floor above
          # the ceiling gives the ceiling. Bounds that need nothing worked out are read straight
          # into the right-hand registers; others are worked out with the number kept aside.
          def value_of_clamped(node)
            value(node.operand)
            return emit_held_by_plain(node.min, node.max) if plain?(node.min) && plain?(node.max)

            kept = kept_place(@depth)
            @depth += 1
            [[node.min, :raise], [node.max, :lower]].each do |bound, way|
              @gsu.sm(kept, LOW)
              @gsu.sm(kept + 2, HIGH)
              value(bound)
              @gsu.move(RIGHT_LOW, LOW)
              @gsu.move(RIGHT_HIGH, HIGH)
              load_place(kept, LOW, HIGH)
              emit_held_at_right(way)
            end
            @depth -= 1
          end

          def emit_held_by_plain(min, max)
            load_plain(min, RIGHT_LOW, RIGHT_HIGH)
            emit_held_at_right(:raise)
            load_plain(max, RIGHT_LOW, RIGHT_HIGH)
            emit_held_at_right(:lower)
          end

          # LOW and HIGH made the right-hand number when they are below it (:raise) or above it
          # (:lower).
          def emit_held_at_right(way)
            keep = fresh("held")
            way == :raise ? emit_flags_of_less(LOW, HIGH, RIGHT_LOW, RIGHT_HIGH) : emit_flags_of_less(RIGHT_LOW, RIGHT_HIGH, LOW, HIGH)
            emit_branch(:bge, keep)
            @gsu.move(LOW, RIGHT_LOW)
            @gsu.move(HIGH, RIGHT_HIGH)
            @gsu.label(keep)
          end

          # --- fractions ---
          #
          # A number with a fraction is a whole number to the chip, multiplied up; what is its own is
          # the product and the quotient of two of them, which are worked out wider than 32 bits
          # (Runtime::ChipSums), and bringing one down, which is a shift.

          def value_of_mul_fix(node)
            with_both_sides(node.lhs, node.rhs)
            @gsu.ibt(12, node.fraction_bits)
            emit_called_sum(Sums::MULTIPLY_FRACTIONS)
          end

          def value_of_div_fix(node)
            with_both_sides(node.lhs, node.rhs)
            @gsu.ibt(12, Sums::NUMBER_BITS + node.fraction_bits)
            emit_called_sum(Sums::DIVIDE_FRACTIONS)
          end

          def value_of_shift_right(node)
            value(node.operand)
            emit_shift_by(:>>, node.bits)
          end

          # --- tests ---

          def jump_if(condition, label)
            known = @plan.folded(condition)
            return if known&.zero?
            return emit_branch(:bra, label) if known

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            emit_branch(:bra, label)
            @gsu.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. Working a side out here changes nothing, so
          # `and` can stop at the first side that does not hold, though the interpreter works both.
          def jump_unless(condition, label)
            known = @plan.folded(condition)
            return (emit_branch(:bra, label) if known.zero?) if known

            if binop?(condition, :and)
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif binop?(condition) && COMPARISONS.include?(condition.op)
              emit_branch(emit_comparison(condition), label)
            else
              value(condition)
              emit_nought_flag(LOW, HIGH)
              emit_branch(:beq, label)
            end
          end

          def binop?(node, op = nil) = node.is_a?(Node) && node.kind == :binop && (op.nil? || node.op == op)

          # The zero flag set when the number in +low+ and +high+ is nought. R0 is scratch.
          def emit_nought_flag(low, high)
            @gsu.from(low)
            @gsu.to(0)
            @gsu.or_(high)
          end

          # The flags left as a comparison says, and the branch taken when it does NOT hold. Equal or
          # not: the two halves' differences together are nought only when both are. Less or more:
          # the left side less the right side, for the sign of the answer.
          def emit_comparison(node)
            with_both_sides(node.lhs, node.rhs)
            case node.op
            when :==, :!=
              @gsu.from(LOW)
              @gsu.to(0)
              @gsu.xor(RIGHT_LOW)
              @gsu.from(HIGH)
              @gsu.to(4)
              @gsu.xor(RIGHT_HIGH)
              @gsu.or_(4)
            when :<, :>= then emit_flags_of_less(LOW, HIGH, RIGHT_LOW, RIGHT_HIGH)
            else emit_flags_of_less(RIGHT_LOW, RIGHT_HIGH, LOW, HIGH)
            end
            FAILS.fetch(node.op)
          end

          # The flags BLT and BGE read for a 32-bit number less another: the subtraction of the low
          # halves leaves only its borrow, and the high halves' leaves the sign and the overflow,
          # which together say which number is the lower however far apart they are. The answer goes
          # to R0 and is not wanted.
          def emit_flags_of_less(low, high, other_low, other_high)
            @gsu.from(low)
            @gsu.cmp(other_low)
            @gsu.from(high)
            @gsu.sbc(other_high)
          end

          # --- values: each leaves its number in LOW and HIGH ---

          def value(operand)
            known = @plan.folded(operand)
            return load_number(known, LOW, HIGH) if known
            return load_variable(operand, LOW, HIGH) if operand.is_a?(Symbol)

            send(VALUES.fetch(operand.kind), operand)
          end

          def value_of_int(node) = load_number(node.value, LOW, HIGH)
          def value_of_var_ref(node) = load_variable(node.name, LOW, HIGH)

          def load_variable(name, low, high) = load_place(place_of(name), low, high)

          def load_place(at, low, high)
            @gsu.lm(low, at)
            @gsu.lm(high, at + 2)
          end

          def load_number(number, low, high)
            number &= 0xFFFF_FFFF
            load_half(number & 0xFFFF, low)
            load_half(number >> 16, high)
          end

          # A half the chip can write in one byte is written in one, sign-extended.
          def load_half(half, register)
            signed = half >= 0x8000 ? half - 0x1_0000 : half
            return @gsu.ibt(register, signed) if signed.between?(-128, 127)

            @gsu.iwt(register, half)
          end

          def variable_named(node)
            return node if node.is_a?(Symbol)

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # A side that needs nothing worked out: a number written in the program, or a variable.
          def plain?(node) = !@plan.folded(node).nil? || !variable_named(node).nil?

          def load_plain(node, low, high)
            known = @plan.folded(node)
            return load_number(known, low, high) if known

            load_variable(variable_named(node), low, high)
          end

          # The left side in LOW and HIGH, the right in RIGHT_LOW and RIGHT_HIGH. Neither side changes
          # anything, so which is worked out first makes no difference to the answer.
          def with_both_sides(left, right)
            return (value(left).then { load_plain(right, RIGHT_LOW, RIGHT_HIGH) }) if plain?(right)
            return emit_right_side_first(left, right) if plain?(left)

            value(right)
            kept = kept_place(@depth)
            @gsu.sm(kept, LOW)
            @gsu.sm(kept + 2, HIGH)
            @depth += 1
            value(left)
            @depth -= 1
            load_place(kept, RIGHT_LOW, RIGHT_HIGH)
          end

          def emit_right_side_first(left, right)
            value(right)
            @gsu.move(RIGHT_LOW, LOW)
            @gsu.move(RIGHT_HIGH, HIGH)
            load_plain(left, LOW, HIGH)
          end

          def value_of_binop(node)
            return value_of_comparison(node) if COMPARISONS.include?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)
            return if emit_written_shift(node) || emit_written_division(node) || emit_small_addition(node)

            with_both_sides(node.lhs, node.rhs)
            label = CALLED_SUMS[node.op]
            return emit_called_sum(label) if label

            low_sum, high_sum = IN_PLACE_SUMS.fetch(node.op)
            @gsu.with(LOW)
            @gsu.public_send(low_sum, RIGHT_LOW)
            @gsu.with(HIGH)
            @gsu.public_send(high_sum, RIGHT_HIGH)
          end

          # A number up to 15 added: the chip has an instruction for that, with the number in it.
          def emit_small_addition(node)
            return false unless node.op == :+

            number = @plan.folded(node.rhs)
            return false unless number&.between?(0, 15)

            value(node.lhs)
            emit_add_small(number)
            true
          end

          def emit_add_small(number)
            @gsu.with(LOW)
            @gsu.add(@gsu.imm(number))
            @gsu.with(HIGH)
            @gsu.adc(@gsu.imm(0))
          end

          def value_of_comparison(node)
            fails = fresh("fails")
            done = fresh("compared")
            emit_branch(emit_comparison(node), fails)
            @gsu.ibt(LOW, 1)
            emit_branch(:bra, done)
            @gsu.label(fails)
            @gsu.ibt(LOW, 0)
            @gsu.label(done)
            @gsu.ibt(HIGH, 0)
          end

          # `and` and `or` as a 1 or a 0. Both sides are worked out, as the interpreter does.
          def value_of_both_or_either(node)
            with_both_sides(node.lhs, node.rhs)
            emit_truth(LOW, HIGH)
            emit_truth(RIGHT_LOW, RIGHT_HIGH)
            @gsu.with(LOW)
            node.op == :and ? @gsu.and_(RIGHT_LOW) : @gsu.or_(RIGHT_LOW)
            @gsu.ibt(HIGH, 0)
          end

          # The number in +low+ and +high+ made a 1 in +low+ when it is not nought, and a 0 when it is.
          def emit_truth(low, high)
            nought = fresh("nought")
            @gsu.with(low)
            @gsu.or_(high)
            emit_branch(:beq, nought)
            @gsu.ibt(low, 1)
            @gsu.label(nought)
          end

          # A shift by a number written in the program. True when it was made so.
          def emit_written_shift(node)
            return false unless %i[<< >>].include?(node.op)

            count = @plan.folded(node.rhs)
            return false unless count

            value(node.lhs)
            emit_shift_by(node.op, count)
            true
          end

          # IR::Int32: a count outside 0 to 31 empties the number. A count of 16 or more starts by
          # moving one half to the other, and what is left is a step at a time, or a call of the
          # routine that does steps in a loop.
          def emit_shift_by(op, count)
            return emit_emptied(op) unless count.between?(0, Sums::NUMBER_BITS - 1)

            steps = count % Sums::HALF_BITS
            if steps > MOST_WRITTEN_STEPS
              load_number(count, RIGHT_LOW, RIGHT_HIGH)
              return emit_called_sum(CALLED_SUMS.fetch(op))
            end

            emit_half_moved(op) if count >= Sums::HALF_BITS
            steps.times { emit_shift_step(op) }
          end

          def emit_emptied(op)
            return load_number(0, LOW, HIGH) if op == :<<

            filled = fresh("filled")
            @gsu.moves(0, HIGH)
            @gsu.ibt(LOW, 0)
            @gsu.ibt(HIGH, 0)
            emit_branch(:bpl, filled)
            @gsu.dec(LOW)
            @gsu.dec(HIGH)
            @gsu.label(filled)
          end

          def emit_half_moved(op)
            if op == :<<
              @gsu.move(HIGH, LOW)
              @gsu.ibt(LOW, 0)
            else
              moved = fresh("moved")
              @gsu.moves(LOW, HIGH)
              @gsu.ibt(HIGH, 0)
              emit_branch(:bpl, moved)
              @gsu.dec(HIGH)
              @gsu.label(moved)
            end
          end

          def emit_shift_step(op)
            if op == :<<
              @gsu.with(LOW)
              @gsu.add(LOW)
              @gsu.with(HIGH)
              @gsu.rol
            else
              @gsu.with(HIGH)
              @gsu.asr
              @gsu.with(LOW)
              @gsu.ror
            end
          end

          # A division by a positive power of two written in the program takes no steps of division.
          # What is left is the low bits, as IR::Int32.mod has it: -1 % 16 is 15, and so is -1 & 15.
          # A quotient is a shift, which rounds down where a quotient rounds toward nought, so a
          # number below nought has the divisor less one added first. True when it was made so.
          def emit_written_division(node)
            return false unless %i[/ %].include?(node.op)

            divisor = @plan.folded(node.rhs)
            return false unless divisor&.positive? && divisor.nobits?(divisor - 1)
            return value(Build.binop(:&, node.lhs, Build.int(divisor - 1))).then { true } if node.op == :%

            value(node.lhs)
            positive = fresh("positive")
            @gsu.moves(0, HIGH)
            emit_branch(:bpl, positive)
            load_number(divisor - 1, RIGHT_LOW, RIGHT_HIGH)
            @gsu.with(LOW)
            @gsu.add(RIGHT_LOW)
            @gsu.with(HIGH)
            @gsu.adc(RIGHT_HIGH)
            @gsu.label(positive)
            emit_shift_by(:>>, divisor.bit_length - 1)
            true
          end
        end
      end
    end
  end
end
