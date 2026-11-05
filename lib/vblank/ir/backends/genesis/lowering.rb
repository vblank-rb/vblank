# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # ONE PROGRAM, LOWERED STRAIGHT TO 68000 MACHINE CODE: the Genesis's peer of the Super
        # Nintendo's, Color's and Advance's lowerings. It walks the IR with a table naming the method
        # for each kind of statement and each kind of value (the interpreter's own shape, Reference),
        # and emits the instructions through the assembler (M68000), calling the runtime
        # (Genesis::Runtime) for what is too long to write in place.
        #
        # HOW A NUMBER IS WORKED OUT. Every value leaves its answer in D0, a data register that is
        # 32 bits wide, as a game's numbers are, so there is never a high half or a low one to
        # keep apart. A sum of two works the left-hand side out into D0 and takes the right-hand side
        # from where it already is — a number written in the program is part of the instruction, a
        # variable is read where it lives — so `x + 1` is two instructions and no call. A right-hand
        # side that has to be worked out first is worked out, pushed on the stack, and pulled into D1
        # once the left-hand side is in D0. A runtime routine taking several numbers has them in
        # D0, D1, D2... Nothing is kept in a register from one statement to the next, so a statement
        # never has to know what came before it.
        #
        # WHERE THINGS LIVE. The game's variables, and each routine's own numbers — a loop's count, a
        # `case`'s reading — are places in work RAM (Memory) fixed while the program is built, so a
        # routine cannot call itself, and a program in which one can is refused. A5 points at the
        # middle of work RAM, and every place is named as a distance from it. Every routine is called
        # with JSR and returns with RTS, so it can be anywhere in the cartridge.
        #
        # It makes the kinds in its two tables, and refuses by name a program that reaches one it does
        # not make yet (NOT_LOWERED_YET), and one a Genesis cannot do at all in the words its
        # answers have (Console::Answers#refusals).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the
          # +part+ of the build that is missing ("the picture"), for a test run to count skips by.
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          include Paint
          include Picture
          include Collision
          include Sound
          include Division

          STATEMENTS = Ractor.make_shareable({
                                               program: :emit_children, set: :emit_set, add: :emit_add,
                                               sub: :emit_sub, copy: :emit_copy, negate: :emit_negate,
                                               abs: :emit_abs, negate_abs: :emit_negate_abs, clamp: :emit_clamp,
                                               if: :emit_if, loop: :emit_loop, repeat: :emit_repeat,
                                               every: :emit_beat, after: :emit_beat, call: :emit_call,
                                               call_one_of: :emit_call_one_of, case: :emit_case,
                                               halt: :emit_halt, wait_vblank: :emit_wait_vblank,
                                               list_new: :emit_list_new, list_push: :emit_list_push,
                                               list_drop: :emit_list_drop, list_set: :emit_list_set,
                                               list_fill: :emit_list_fill, list_copy: :emit_list_copy,
                                               list_sort: :emit_list_sort,
                                               timer_start: :emit_timer_start, timer_stop: :emit_timer_stop,
                                               # a timer's handler runs as its timer ticks, not where it is written
                                               on_timer: :emit_nothing,
                                               # no light can be made on a Genesis (its answers refuse one), and a
                                               # game without one works nothing out again
                                               show_light_now: :emit_nothing,
                                               # a Genesis cartridge has no rumble motor, so nothing is felt
                                               # (Console::Description#rumbles)
                                               rumble: :emit_nothing,
                                               # video memory is written only between frames here, so a
                                               # held background's changes already show together
                                               show_held_tiles: :emit_nothing,
                                               # every picture is in video memory whichever group is up (the
                                               # interpreter's own check is all that groups are for here)
                                               show_picture_group: :emit_nothing,
                                               # a tiled screen is the one the console is set up for at power-on
                                               screen: :emit_nothing
                                             }.merge(Paint::STATEMENTS).merge(Picture::STATEMENTS).merge(Sound::STATEMENTS)
                                              .merge(Nodes.of_role(:declaration).to_h { |kind| [kind, :emit_nothing] }))

          VALUES = Ractor.make_shareable({
                                           int: :value_of_int, var_ref: :value_of_var_ref, binop: :value_of_binop,
                                           neg: :value_of_neg, bit_not: :value_of_bit_not,
                                           absolute: :value_of_absolute, clamped: :value_of_clamped,
                                           shift_right: :value_of_shift_right, held: :value_of_held,
                                           pressed: :value_of_pressed, list_get: :value_of_list_get,
                                           list_len: :value_of_list_len, table_get: :value_of_table_get,
                                           timer_ticks: :value_of_timer_ticks, chance: :value_of_chance,
                                           mul_fix: :value_of_mul_fix, div_fix: :value_of_div_fix,
                                           data_byte: :value_of_data_byte, players_connected: :value_of_players_connected,
                                           local_player: :value_of_local_player
                                         }.merge(Collision::VALUES))

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list the
          # day the Genesis does it; test_genesis_kind_coverage.rb holds the list and the tables above
          # to every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({
                                                    "the status bar" => %i[place_bar],
                                                    "backgrounds bent row by row" => %i[scroll_rows],
                                                    "tiles painted from a list" => %i[copy_tiles copy_owed_tiles],
                                                    "sprite tiles the game loads" => %i[load_sprite_tiles],
                                                    "layers see-through" => %i[see_through],
                                                    "the picture" => %i[draw_column_at],
                                                    "save memory" => %i[save_init save_store save_write save_erase
                                                                        save_read save_sum]
                                                  })

          # How the runtime's list copy knows each way of keeping an entry (Runtime::Lists::KEPT), by
          # its bytes and its sign (LoweringPlan#table_keeping).
          TABLE_KEPT = Ractor.make_shareable({ [1, true] => :signed_byte, [1, false] => :byte, [2, true] => :signed_half,
                                               [2, false] => :half, [4, true] => :word })

          # The runtime's routines for a binop worked out by a call.
          CALLED_SUMS = Ractor.make_shareable({ :* => "rt_mul32", :/ => "rt_div32", :% => "rt_mod32",
                                                :<< => "rt_shl32", :>> => "rt_shr32" })
          IN_PLACE_SUMS = Ractor.make_shareable({ :+ => :add, :- => :sub, :& => :and, :| => :or, :^ => :eor })
          COMPARISONS = %i[< <= > >= == !=].freeze

          # The condition under which a comparison does NOT hold, which is where a branch over what
          # follows it goes, and the one under which it does (the flags are those of `cmp right,left`).
          FAILS_WHEN = Ractor.make_shareable({ :== => :ne, :!= => :eq, :< => :ge, :<= => :gt, :> => :le, :>= => :lt })
          HOLDS_WHEN = Ractor.make_shareable({ :== => :eq, :!= => :ne, :< => :lt, :<= => :le, :> => :gt, :>= => :ge })

          # What the game's code is to the author, for a cartridge too full for it (Linker::TooBig).
          DATA = M68000::Holding.new(what: "the game's tables", fix: "make its tables shorter, or use fewer of them")
          ROUTINES = M68000::Holding.new(what: "the game's routines", fix: "make its routines shorter, or use fewer of them")

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # Where each of the game's variables went, by its name, and each of its lists — [its place,
          # its capacity, the bytes a slot, its name] — once #sections has placed them; the label of
          # the routine the runtime runs at each frame boundary, or nil for a game with no timers; and
          # each routine's section, by its label, beside what that routine is to the author.
          attr_reader :variables, :lists, :frame_begins, :section_routines

          # +scene_tiles+ keeps each scene's own tiles in video memory only while it is up (Art), for a
          # game whose tiles together do not fit (Genesis#build): :backgrounds for its backgrounds'
          # tiles alone, :sprites for its sprite pictures' too. +cache+ is what the build works out
          # from the program once for all its tries (BuildCache).
          def initialize(program, memory:, scene_tiles: false, cache: BuildCache.for(Genesis, program))
            @program = program
            @cache = cache
            @memory = memory
            @scene_tiles = scene_tiles
            # What the program is before any instruction is made, worked out as the Color's and the
            # Super Nintendo's are (LoweringPlan), once a build, and kept here under the names the
            # rest of the lowering reads.
            @plan = cache.plan
            @funcs = @plan.funcs
            @tick_handlers = @plan.tick_handlers
            @timers = @plan.timers
            @called = @plan.called
            @reachable = @plan.reachable
            @declared_lists = @plan.declared_lists
            @tables = @plan.tables
            @handover = @plan.handover
            @scenes = @plan.scenes
            @lists = {}
            @lists_dropped_from_front = lists_dropped_from_front(program)
            @direct_slot_sizes = [] # the slot sizes the game reads or writes directly (#list_routine)
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @section_routines = {}
            @pictures = by_kind(:bitmap)
            prepare_paint
            prepare_picture
            prepare_collision
            prepare_sound
            @cuts = RoutineCuts.for(self, cache)
          end

          # The console this lowers for (BuildCache).
          CONSOLE = Console::GENESIS

          # How the program draws: :painted, :tiled (it says `screen :tiled`, or has a background or a
          # sprite) or :none.
          def self.picture_of(program)
            return :painted if Paint.painted?(program)

            tiled = program.walk.any? do |node|
              %i[background object].include?(node.kind) || (node.kind == :screen && node.mode == :tiled)
            end
            tiled ? :tiled : :none
          end

          # How many words of the video chip's register table the cartridge's power-on writes
          # (#sections makes the table).
          def register_count = VIDEO_REGISTERS.length

          # Whether the game fades or tints, which is when two colours of its own that the console shows alike
          # are kept apart (Art#initialize's +exact+).
          def self.fading?(program) = program.walk.any? { |node| %i[fade tint].include?(node.kind) }

          # Whether the game changes its colours as it runs: it fades, tints, or has a list of colours told
          # to hold others (a sprite's, or a background's), which is when its cartridge carries Runtime::Tint.
          def self.changing_colors?(program)
            program.walk.any? { |node| %i[fade tint color_list_holds background_colors].include?(node.kind) }
          end

          # Whether the game holds numbers with a fraction, which is when the cartridge carries the
          # routines that work them out (Runtime::Int32.emit_fractions).
          def fractions? = @program.walk.any? { |node| %i[mul_fix div_fix].include?(node.kind) }

          # The slot sizes, in bytes, whose direct routines the game calls, so the runtime carries
          # only those (Runtime::Lists#emit_fixed_front_access). Known once #sections has run.
          def direct_slot_sizes = @direct_slot_sizes.sort


          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            refuse_unlowered_kinds!
            @plan.refuse_routines_that_call_themselves!
            @plan.refuse_what_console_lacks!
            refuse_unmade_picture!
            assign_background_layers unless painted?
            make_sprite_art
            (Reach.variables(@program) | loop_variables).each do |name|
              @variables[name] = @memory.reserve("the variable #{name.inspect}", 4)
            end
            @declared_lists.each_value do |node|
              width = LoweringPlan::SLOT_BYTES.fetch(node.width)
              place = @memory.reserve("the list #{node.name.inspect}", Runtime::Lists::HEADER + (node.capacity * width))
              @lists[node.name] = [place, node.capacity, width, node.name.to_s]
            end
            reserve_patches
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            keep_corner_notes
            keep_loop_running
            routines = @called.flat_map do |name|
              @lowering_scene = @scenes.key?(name) ? name : nil
              routines_fitting(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
            end
            timers = timer_sections
            @lowering_scene = nil
            main = routines_fitting(MAIN, @program.children, routine: "the game loop")
            placings = sprite_placing_sections
            [data_section, video_registers_section, *table_sections, *routines, *timers, *main, *placings,
             *paint_sections, *art_sections, *collision_sections]
          end

          private

          def by_kind(kind) = @program.walk.select { |node| node.kind == kind }.to_h { |node| [node.name, node] }

          def picture_named(name)
            @pictures.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
          end

          # The variables the game loops keep of their own, in the console's order
          # (IR::Frames::ConsoleLoop).
          def loop_variables = @plan.game_loops.flat_map { |node| console_loop(node).variables }

          # --- refusals ---

          # What a run can reach and this lowering cannot make, refused by name before anything is
          # made: a step that only means something on the Advance, and one the Genesis build does not
          # make yet. A step in a routine nothing calls never runs, and is not refused.
          def refuse_unlowered_kinds!
            @plan.refuse_hardware_only_kinds!
            @plan.refuse_kinds_not_made_yet!(NOT_LOWERED_YET, NotMadeYet)
          end

          # --- the data ---

          # The video chip's registers at power-on, a word each: the register's number and its
          # value (Console::GenesisHardware's REG_ names). The screen is off and its interrupt
          # too, 40 tiles across, two planes of 64 across and 32 down, the pictures' memories where
          # Runtime::Picture keeps them.
          VIDEO_REGISTERS = Ractor.make_shareable(
            [[Console::GenesisHardware::REG_MODE1, Console::GenesisHardware::MODE1_NORMAL],
             [Console::GenesisHardware::REG_MODE2, Console::GenesisHardware::MODE2_SCREEN_OFF],
             [Console::GenesisHardware::REG_PLANE_A, 0xC000 >> 10],
             [Console::GenesisHardware::REG_WINDOW, 0],
             [Console::GenesisHardware::REG_PLANE_B, 0xE000 >> 13],
             [Console::GenesisHardware::REG_SPRITES, 0xBC00 >> 9],
             [6, 0],
             [Console::GenesisHardware::REG_BACKDROP, 0],
             [8, 0],
             [9, 0],
             [Console::GenesisHardware::REG_HINT, 0xFF],
             [Console::GenesisHardware::REG_MODE3, 0],
             [Console::GenesisHardware::REG_MODE4, Console::GenesisHardware::MODE4_40_CELLS],
             [Console::GenesisHardware::REG_HSCROLL, 0xB800 >> 10],
             [14, 0],
             [Console::GenesisHardware::REG_INCREMENT, Console::GenesisHardware::INCREMENT_WORD],
             [Console::GenesisHardware::REG_PLANE_SIZE, 0x01],
             [Console::GenesisHardware::REG_WINDOW_X, 0],
             [Console::GenesisHardware::REG_WINDOW_Y, 0]]
          )

          # The planes' size, as the register says it: a tiled screen's own, and for any other the 64 across
          # and 32 down a painted screen's map is laid out in (Runtime::Paint).
          def plane_size_register
            return 0x01 unless tiled?

            columns, rows = plane_size
            (columns == 64 ? 0x01 : 0x00) | (rows == 64 ? 0x10 : 0x00)
          end

          def video_registers_section
            asm = M68000.new("video registers")
            asm.label("rt_vdp_registers")
            words = VIDEO_REGISTERS.map do |register, value|
              value = plane_size_register if register == Console::GenesisHardware::REG_PLANE_SIZE
              value = backdrop_register if register == Console::GenesisHardware::REG_BACKDROP
              Console::GenesisHardware::VDP_REGISTER | (register << 8) | value
            end
            asm.data_words(words)
            asm.section
          end

          # The places that do not start at nought (each an address and a number, as longs, and an
          # address of nought after the last), each list's address, capacity and slot (the runtime's
          # start reads them), and the tables of routines a call picks from by number.
          def data_section
            asm = M68000.new("game data", holds: DATA)
            asm.label("game_starts")
            @starts.each { |address, value| asm.data_longs(address, value) }
            asm.data_longs(0)
            asm.label("game_lists")
            @lists.each_value do |place, capacity, width, _|
              asm.data_longs(place)
              asm.data_words(capacity, width.bit_length - 1)
            end
            asm.data_longs(0)
            @routine_tables.each do |targets, label|
              asm.label(label)
              asm.data_longs(targets.map { |name| self.class.routine_label(name) })
            end
            asm.section
          end

          # Each table a run reads, in a section of its own: its entries as the cartridge keeps them
          # (LoweringPlan#table_keeping), the high byte first.
          def table_sections
            tables_read.map do |table|
              bytes, = table_keeping(table)
              asm = M68000.new(table_label(table.name), holds: DATA)
              asm.label(table_label(table.name))
              asm.data_bytes(table.values.flat_map { |entry| big_endian(Int32.wrap(entry), bytes) })
              asm.section
            end
          end

          def tables_read = @plan.tables_read

          def table_label(name) = "table #{name}"

          def table_keeping(table) = @plan.table_keeping(table)

          def big_endian(value, size) = Array.new(size) { |i| (value >> (8 * (size - 1 - i))) & 0xFF }

          # --- routines ---

          # A routine of +body+'s statements, or of what the block emits for one this lowering makes
          # for itself. +routine+ is what it is to the author.
          def routine_section(label, body, routine:)
            @section_routines[label] = routine
            @asm = M68000.new(label, holds: ROUTINES)
            @routine = label
            @labels = 0
            @asm.label(label)
            body.each { |node| statement(node) }
            yield if block_given?
            @asm.rts
            @asm.section
          end

          def routine_said(name) = @plan.routine_said(name)

          # A label no other in the routine has: +what+ and the count, apart, as GBC::Lowering#fresh.
          def fresh(what)
            @labels += 1
            "#{@routine}.#{what}##{@labels}"
          end

          # A number of the routine's own, kept in work RAM, by a name of its own that a value can
          # read as a variable. +start+ is what it holds from power-on.
          def keep_local(what, start: 0)
            name = :"#{@routine || 'game'}.#{what}#{@locals.length + 1}"
            @locals[name] = @memory.reserve("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          # Where the variable +name+ (or a number of a routine's own) is kept, as an address.
          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # The operand that names that place: a distance from A5.
          def var(name) = at(place_of(name))

          def at(address, plus = 0) = @asm.disp(5, Memory.displacement(address) + plus)

          # A runtime place by name, as an operand.
          def runtime_at(name, plus = 0) = at(@memory[name], plus)

          # A routine of the game's, or the runtime's, called wherever it is.
          def call_routine(label) = @asm.jsr(@asm.abs_l(label))

          # --- a routine too big to branch across, cut into parts ---

          # The most bytes one routine's code may come to before it is cut into parts, each a routine
          # of its own. A branch inside a routine is a distance of 16 bits, so a routine stays well
          # under 32K, and what is left after the cut also has calls of its parts in it.
          MOST_ROUTINE_BYTES = 24_000

          # The most bytes a part cut off a routine may come to.
          MOST_PART_BYTES = 12_000

          # The routine +label+ of +body+'s statements, and the parts cut off it to keep each within
          # reach of its own branches (RoutineCuts#sections), each a section of its own.
          def routines_fitting(label, body, routine:)
            @cuts.sections(label, body) { |part, statements| routine_section(part, statements, routine: routine) }
          end

          # The statements +node+ holds, and an `if`'s other side: as cut, when they were
          # (RoutineCuts#children_of).
          def children_of(node) = @cuts.children_of(node)

          # How many bytes +list+ comes to, made on copies of what the lowering holds and thrown away
          # (LoweringState#on_copies).
          def bytes_of(list)
            LOWERING_STATE.on_copies(self) do
              @asm = M68000.new("measuring", holds: ROUTINES)
              @routine = "measuring"
              @labels = 0
              list.each { |node| statement(node) }
              @asm.here
            end
          end

          # RTS, which ends every routine section: two bytes.
          RETURN_BYTES = 2

          # What the lowering holds while it makes a statement (LoweringState). Copied all the way
          # down: the work RAM it reserves and the pictures and colours it gathers. Shared: numbers,
          # names, the program and what is worked out from it before any statement is made. Left
          # alone: the statements already cut into parts, which only cutting adds to, and what the
          # build worked out once (BuildCache).
          LOWERING_STATE = LoweringState.new(
            copied: [Memory, PaintedArt, Art],
            shared: [Integer, Symbol, String, NilClass, TrueClass, FalseClass, IR::Node, SceneHandover, SpriteNames,
                     M68000, Music, RoutineCuts::PartCall, LoweringPlan],
            unchanged: %i[@cuts @cache]
          )

          # --- statements ---

          def statement(node)
            return call_routine(node.label) if node.is_a?(RoutineCuts::PartCall)

            send(STATEMENTS.fetch(node.kind), node)
          end

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # D0 into the variable +name+.
          def store(name) = @asm.move(:l, @asm.d(0), var(name))

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            known = folded(node.value)
            return store_number(node.var, known) if known

            name = variable_named(node.value)
            return @asm.move(:l, var(name), var(node.var)) if name

            value(node.value)
            store(node.var)
          end

          # A number written in the program, straight into the variable +name+.
          def store_number(name, number)
            return @asm.clr(:l, var(name)) if number.zero?

            @asm.move(:l, @asm.imm(number), var(name))
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`, in place when n is a number written in the program or a
          # variable: one instruction, or two.
          def emit_sum(name, op, operand)
            known = folded(operand)
            return emit_sum_of_number(name, op, known) if known

            other = variable_named(operand)
            unless other
              value(Build.binop(op, Build.var_ref(name), operand))
              return store(name)
            end

            @asm.move(:l, var(other), @asm.d(0))
            @asm.public_send(IN_PLACE_SUMS.fetch(op), :l, @asm.d(0), var(name))
          end

          def emit_sum_of_number(name, op, number)
            number = -number if op == :-
            return if number.zero?

            if number.between?(1, 8)
              @asm.addq(:l, number, var(name))
            elsif number.between?(-8, -1)
              @asm.subq(:l, -number, var(name))
            else
              @asm.add(:l, @asm.imm(number), var(name))
            end
          end

          def emit_copy(node)
            return if node.dest == node.src

            name = variable_named(node.src)
            return @asm.move(:l, var(name), var(node.dest)) if name

            value(node.src)
            store(node.dest)
          end

          def emit_negate(node) = @asm.neg(:l, var(node.var))

          def emit_abs(node)
            value(Build.absolute(Build.var_ref(node.var)))
            store(node.var)
          end

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def emit_negate_abs(node)
            done = fresh("not_above_nought")
            @asm.tst(:l, var(node.var))
            @asm.branch(:le, done)
            emit_negate(node)
            @asm.label(done)
          end

          def emit_clamp(node)
            value(Build.clamped(Build.var_ref(node.var), node.min, node.max))
            store(node.var)
          end

          def emit_if(node)
            body, otherwise = children_of(node)
            known = folded(node.cond)
            return (known.zero? ? otherwise : body).each { |child| statement(child) } if known

            other = fresh("else")
            done = fresh("end_if")
            jump_unless(node.cond, other)
            body.each { |child| statement(child) }
            @asm.bra(done) unless otherwise.empty?
            @asm.label(other)
            otherwise.each { |child| statement(child) }
            @asm.label(done)
          end

          def emit_loop(node)
            console_loop(node).before.each { |child| statement(child) }
            statement(Build.set(@loop_running, (loops_ending_passes.index(node) || -1) + 1)) if @loop_running
            top = fresh("loop")
            @asm.label(top)
            children_of(node).first.each { |child| statement(child) }
            @asm.bra(top)
          end

          def console_loop(node) = @plan.console_loop(node)

          # Is +node+ one of the boundary's writes a game loop places at the end of its pass, or in
          # one (IR::Frames::ConsoleLoop#placed)?
          def placed_at_pass_end?(node)
            @placed_at_pass_end ||= @plan.game_loops.flat_map { |loop_node| console_loop(loop_node).placed.flat_map { |write| write.walk.to_a } }
                                         .to_h { |write| [write.object_id, true] }
            @placed_at_pass_end.key?(node.object_id)
          end

          # The game loops that end each pass by placing the display's writes
          # (IR::Frames::ConsoleLoop#pass_end), which a halt has to end as the running one does.
          def loops_ending_passes
            @loops_ending_passes ||= @plan.game_loops.select { |node| console_loop(node).pass_end.any? }
          end

          # Which of those is running, counted from 1, and nought for none, in a game with any: a
          # halt can be anywhere, in a routine called from any loop or from none (#emit_halt).
          def keep_loop_running
            @loop_running = keep_local(:loop_running) if loops_ending_passes.any?
          end

          # Reference#exec_repeat: the count worked out once, before the first pass; the index
          # counting 0, 1, 2... and stored in the game's variable at the top of each pass; and
          # +stop_when+ asked BEFORE the body, so a loop already finished on its first pass runs the
          # body no times.
          def emit_repeat(node)
            count = keep_local(:count)
            index = keep_local(:index)
            value(node.count)
            store(count)
            store_number(index, 0)
            top = fresh("repeat")
            done = fresh("end_repeat")
            @asm.label(top)
            jump_unless(Build.binop(:<, Build.var_ref(index), Build.var_ref(count)), done)
            if node.index
              value(index)
              store(node.index)
            end
            jump_if(node.stop_when, done)
            children_of(node).first.each { |child| statement(child) }
            emit_sum(index, :+, Build.int(1))
            @asm.bra(top)
            @asm.label(done)
          end

          # A beat (`every`, `after`) is the plain statements IR::Frames says it means.
          def emit_beat(node) = Frames.beat_statements(node).each { |child| statement(child) }

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)

            call_routine(self.class.routine_label(node.target))
          end

          # Reference#exec_call_one_of: the number worked out once, and a number naming no routine of
          # the list — below nought or past its end — calls nothing. Compared as a number that cannot
          # be negative, -1 is the biggest there is, so one test guards both ends. The routine is
          # reached through a table of their addresses, a long each.
          def emit_call_one_of(node)
            table = @routine_tables[node.targets] ||= "routines #{@routine_tables.length + 1}"
            none = fresh("calls_none")
            value(node.which)
            @asm.cmp(:l, @asm.imm(node.targets.length), @asm.d(0))
            @asm.branch(:cc, none)
            @asm.lsl(:l, 2, @asm.d(0))
            @asm.lea(@asm.abs_l(table), @asm.a(0))
            @asm.movea(:l, @asm.idx(0, 0, 0), @asm.a(0))
            @asm.jsr(@asm.ind(0))
            @asm.label(none)
          end

          # Reference#exec_case: the variable read ONCE, before the first clause. A scene's usual last
          # act is to set it to the next scene, and reading it again per clause would run that one
          # too, in the same pass.
          def emit_case(node)
            state = keep_local(:state)
            value(node.var)
            store(state)
            node.clauses.each do |number, target|
              skip = fresh("next_clause")
              jump_unless(Build.binop(:==, Build.var_ref(state), Build.int(number)), skip)
              emit_scene(target)
              @asm.label(skip)
            end
          end

          # A scene taking over is remembered, so what a scene does as it arrives happens on the frame
          # it changes and not again while it stays. A scene that loads first and is handed over to has
          # that pass to itself, and its routine runs from the pass after; the scene up at power-on,
          # which nothing handed over to, runs on the first pass all the same
          # (IR::SceneHandover::Arrival#loads_first?). Before any scene, the note holds -1.
          def emit_scene(scene)
            number = @scenes.fetch(scene)
            label = self.class.routine_label(scene)
            staying = fresh("scene_staying")
            done = fresh("scene_done")
            jump_unless(Build.binop(:!=, Build.var_ref(@scene), Build.int(number)), staying)
            if @handover.arrival(scene).loads_first?
              at_power_on = keep_local(:at_power_on)
              value(Build.binop(:==, Build.var_ref(@scene), Build.int(-1)))
              store(at_power_on)
              emit_scene_number(number)
              jump_unless(Build.var_ref(at_power_on), done)
              call_routine(label)
              @asm.bra(done)
            else
              emit_scene_number(number)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          # The note of the scene running now, set to +number+.
          def emit_scene_number(number)
            return store_number(@scene, number) if painted? || (@scene_layers.zero? && !@scene_tiles)

            before = keep_local(:scene_before)
            statement(Build.set(before, Build.var_ref(@scene)))
            store_number(@scene, number)
            emit_scene_arrival(@scenes.key(number), before)
          end

          # A pass that halts ends as every pass does, with its sprites and scroll placed
          # (IR::Frames::ConsoleLoop#pass_end), as the interpreter ends it
          # (Reference#place_pass_end_before_halt), and nothing before any runs.
          def emit_halt(_node)
            loops_ending_passes.each_with_index do |ending, i|
              other = fresh("not_this_loop")
              jump_unless(Build.binop(:==, Build.var_ref(@loop_running), Build.int(i + 1)), other)
              console_loop(ending).pass_end.each { |child| statement(child) }
              @asm.label(other)
            end
            @asm.jmp(@asm.abs_l("rt_halt"))
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them
          # (Reference#store_frame_counters): the frames shown by every frame the pass took, and what
          # the game catches up by held at the cap, both as the runtime counted them.
          def emit_wait_vblank(_node)
            call_routine("rt_wait_vblank")
            emit_corners_forgotten
            @asm.moveq(0, @asm.d(0))
            @asm.move(:w, runtime_at(Runtime::Frame::FRAMES_TAKEN), @asm.d(0))
            @asm.add(:l, @asm.d(0), var(Frames::COUNT))
            @asm.moveq(0, @asm.d(0))
            @asm.move(:w, runtime_at(Runtime::Frame::STEP_TAKEN), @asm.d(0))
            @asm.move(:l, @asm.d(0), var(Frames::STEP))
            @asm.move(:l, var(Frames::COUNT), var(Frames::SEEN))
          end

          # --- lists (Runtime::Lists does the work and the checking) ---

          # Reference::ListValue.of: empty, or holding its capacity of the one number it is full of.
          def emit_list_new(node)
            return list_call("rt_list_empty", node) unless node.full_of

            list_call("rt_list_at_capacity", node)
            list_call("rt_list_fill", node, Build.int(0), Build.int(node.capacity), Build.int(node.full_of))
          end
          def emit_list_push(node) = list_call("rt_list_push", node, node.value)
          def emit_list_drop(node) = list_call("rt_list_drop", node, Build.int(node.from == :front ? 1 : 0))
          def emit_list_fill(node) = list_call("rt_list_fill", node, node.from, node.count, node.value)
          # A LIST THAT ALWAYS HOLDS ITS CAPACITY, read or written at a number written in the program
          # below that capacity: the slot is at an address known here, and the index can never be
          # outside the list, so the item is one MOVE to or from that address, where the runtime's
          # routine takes the list's place handed over, a call, the index checked and scaled, and the
          # return. A draw order sets the number of each of its things this way every pass.
          def emit_list_set(node)
            slot = fixed_slot(node)
            return list_call(list_routine("rt_list_set", node), node, node.index, node.value) unless slot

            value(node.value)
            @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot.last), @asm.d(0), @asm.abs_l(slot.first))
          end

          def value_of_list_get(node)
            slot = fixed_slot(node)
            return list_call(list_routine("rt_list_get", node), node, node.index) unless slot

            address, bytes = slot
            @asm.move(Runtime::Lists::SLOT_SIZES.fetch(bytes), @asm.abs_l(address), @asm.d(0))
            @asm.ext(:w, @asm.d(0)) if bytes == 1
            @asm.ext(:l, @asm.d(0)) if bytes < 4
          end

          # [the address of the slot, its bytes] that +node+'s index names, when the index is a number
          # written in the program and the list always holds its capacity, which the number is below;
          # or nil.
          def fixed_slot(node)
            capacity = always_full_lists[node.name]
            index = capacity && folded(node.index)
            return unless index&.between?(0, capacity - 1)

            place, _capacity, bytes = @lists.fetch(node.name)
            [place + Runtime::Lists::HEADER + (index * bytes), bytes]
          end

          # The lists made full of one number and never made longer or shorter, so each holds its
          # capacity for good, by name, with that capacity (the least, if made twice). Every way a
          # list's length changes is a list_push, a list_drop, a list_copy, or a list_new that makes it
          # empty; a list_fill or a list_sort leaves it as long as it was. Nothing taken from the
          # front, so the first item stays in the first slot.
          def always_full_lists
            @always_full_lists ||= begin
              resized = @program.walk.filter_map do |node|
                node.name if %i[list_push list_drop list_copy].include?(node.kind) || (node.kind == :list_new && !node.full_of)
              end
              made = @program.walk.select { |node| node.kind == :list_new && node.full_of && !resized.include?(node.name) }
              made.group_by(&:name).transform_values { |nodes| nodes.map(&:capacity).min }
            end
          end
          def value_of_list_len(node) = list_call("rt_list_length", node)

          # The routine that reads or writes an item of the list +node+ names: for a list whose first
          # item is always in its first slot, the one for its slots' size, which goes straight to
          # the slot (Runtime::Lists#emit_fixed_front_access); for any other, +routine+ itself.
          def list_routine(routine, node)
            return routine if @lists_dropped_from_front.include?(node.name)

            bytes = @lists.fetch(node.name)[2]
            @direct_slot_sizes |= [bytes]
            "#{routine}_#{Runtime::Lists::SLOT_SUFFIXES.fetch(bytes)}"
          end

          # The lists the game ever takes an item from the front of, which are the only lists whose
          # first item can be anywhere but their first slot: every other way a list changes leaves it
          # there, or puts it back.
          def lists_dropped_from_front(program)
            program.walk.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }.uniq
          end

          # A run of a table's entries copied into a list: the table's place and how it keeps its
          # entries, so the runtime reads them as a run does.
          def emit_list_copy(node)
            table = @tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
            kept = Runtime::Lists::KEPT.fetch(TABLE_KEPT.fetch(table_keeping(table)))
            list_call("rt_list_copy", node, LabelAddress.new(table_label(table.name)), Build.int(kept),
                      Build.int(table.values.length), node.at, Build.int(node.count))
          end

          # A LIST PUT IN ORDER (Reference#exec_list_sort), written here in place: an insertion sort,
          # each item in turn taken out and moved back past every item before it whose number is
          # strictly beyond its own, so level items keep their order and a list already in order is
          # one compare an item. Both lists' places are known here, so the items are walked with a
          # pointer in A2 and A3 (the one being placed, and the gap moving back), and a number is read
          # with the item as the index from A1, the first of the numbers' slots. Nothing is checked:
          # every item is a place in +by+ (IR ListSort).
          #
          # A list the game takes items from the front of goes round its slots like a ring, so its
          # first item can be in any slot; it is sorted by index instead, each slot found as the
          # runtime finds one (#emit_ring_slot).
          def emit_list_sort(node)
            order = @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is sorted and never declared" }
            keys = @lists.fetch(node.by) { raise LoweringError, "the list #{node.by.inspect} is sorted by and never declared" }
            stays = node.descending ? :ge : :le # the number before is not beyond this one's: it stays
            done = fresh("sorted")
            @asm.moveq(0, @asm.d(7))
            @asm.move(:w, @asm.abs_l(order.first, Runtime::Lists::LENGTH), @asm.d(7))
            @asm.lea(@asm.abs_l(keys.first, Runtime::Lists::HEADER), @asm.a(1))
            if @lists_dropped_from_front.include?(node.name)
              emit_ring_sort(order, keys, stays, done)
            else
              emit_pointer_sort(order, keys, stays, done)
            end
            @asm.label(done)
          end

          # The sort over a list whose first item is in its first slot. D7 counts the items left to
          # place, from the second; D3 is the one being placed and D4 its number; D5 the one before
          # the gap and D6 its number.
          def emit_pointer_sort(order, keys, stays, done)
            size = Runtime::Lists::SLOT_SIZES.fetch(bytes = order[2])
            item = fresh("sort_item")
            back = fresh("sort_back")
            stay = fresh("sort_stay")
            place = fresh("sort_place")
            @asm.subq(:l, 1, @asm.d(7))
            @asm.branch(:le, done)
            @asm.lea(@asm.abs_l(order.first, Runtime::Lists::HEADER), @asm.a(0))
            @asm.movea(:l, @asm.a(0), @asm.a(2))
            @asm.label(item)
            @asm.lea(@asm.disp(2, bytes), @asm.a(2))
            emit_order_item_read(size, @asm.ind(2), 3)
            emit_order_number_read(keys, 3, 4)
            @asm.movea(:l, @asm.a(2), @asm.a(3))
            @asm.label(back)
            @asm.cmp(:l, @asm.a(0), @asm.a(3))
            @asm.branch(:eq, place)
            emit_order_item_read(size, @asm.pre(3), 5)
            emit_order_number_read(keys, 5, 6)
            @asm.cmp(:l, @asm.d(4), @asm.d(6))
            @asm.branch(stays, stay)
            @asm.move(size, @asm.d(5), @asm.disp(3, bytes))
            @asm.bra(back)
            @asm.label(stay)
            @asm.lea(@asm.disp(3, bytes), @asm.a(3))
            @asm.label(place)
            @asm.move(size, @asm.d(3), @asm.ind(3))
            @asm.subq(:l, 1, @asm.d(7))
            @asm.branch(:ne, item)
          end

          # The sort over a list that goes round its slots, by index: D1 the item being placed, D2 the
          # gap, D7 how many there are; the slots found by #emit_ring_slot into A2 and A3.
          def emit_ring_sort(order, keys, stays, done)
            size = Runtime::Lists::SLOT_SIZES.fetch(order[2])
            item = fresh("sort_item")
            back = fresh("sort_back")
            place = fresh("sort_place")
            @asm.moveq(1, @asm.d(1))
            @asm.cmp(:l, @asm.d(7), @asm.d(1))
            @asm.branch(:ge, done)
            @asm.label(item)
            emit_ring_slot(order, 1, 2)
            emit_order_item_read(size, @asm.ind(2), 3)
            emit_order_number_read(keys, 3, 4)
            @asm.move(:l, @asm.d(1), @asm.d(2))
            @asm.label(back)
            @asm.tst(:l, @asm.d(2))
            @asm.branch(:eq, place)
            @asm.move(:l, @asm.d(2), @asm.d(0))
            @asm.subq(:l, 1, @asm.d(0))
            emit_ring_slot(order, 0, 3)
            emit_order_item_read(size, @asm.ind(3), 5)
            emit_order_number_read(keys, 5, 6)
            @asm.cmp(:l, @asm.d(4), @asm.d(6))
            @asm.branch(stays, place)
            emit_ring_slot(order, 2, 3)
            @asm.move(size, @asm.d(5), @asm.ind(3))
            @asm.subq(:l, 1, @asm.d(2))
            @asm.bra(back)
            @asm.label(place)
            emit_ring_slot(order, 2, 3)
            @asm.move(size, @asm.d(3), @asm.ind(3))
            @asm.addq(:l, 1, @asm.d(1))
            @asm.cmp(:l, @asm.d(7), @asm.d(1))
            @asm.branch(:lt, item)
          end

          # D(+into+) = the item at +from+, a place in the numbers' list, so never below nought.
          def emit_order_item_read(size, from, into)
            @asm.moveq(0, @asm.d(into)) unless size == :l
            @asm.move(size, from, @asm.d(into))
          end

          # D(+into+) = the number the list +keys+ holds at the place in D(+item+), widened by its sign.
          # D6 is worked with.
          def emit_order_number_read(keys, item, into)
            bytes = keys[2]
            if @lists_dropped_from_front.include?(keys.last.to_sym)
              emit_ring_slot(keys, item, 4)
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(bytes), @asm.ind(4), @asm.d(into))
            else
              @asm.move(:l, @asm.d(item), @asm.d(6))
              (bytes.bit_length - 1).times { @asm.add(:l, @asm.d(6), @asm.d(6)) }
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(bytes), @asm.idx(1, 0, 6), @asm.d(into))
            end
            @asm.ext(:w, @asm.d(into)) if bytes == 1
            @asm.ext(:l, @asm.d(into)) if bytes < 4
          end

          # A(+into+) = the slot of +list+ that the index in D(+index+) names, for a list going round
          # its slots: its first item's slot and the index, once round the ring if that is past the
          # last slot (Runtime::Lists#emit_slot_access). D6 is worked with.
          def emit_ring_slot(list, index, into)
            place, _capacity, bytes = list
            within = fresh("ring_within")
            @asm.move(:w, @asm.abs_l(place, Runtime::Lists::FRONT), @asm.d(6))
            @asm.add(:w, @asm.d(index), @asm.d(6))
            @asm.cmp(:w, @asm.abs_l(place, Runtime::Lists::CAPACITY), @asm.d(6))
            @asm.branch(:cs, within)
            @asm.sub(:w, @asm.abs_l(place, Runtime::Lists::CAPACITY), @asm.d(6))
            @asm.label(within)
            @asm.and(:l, @asm.imm(0xFFFF), @asm.d(6))
            (bytes.bit_length - 1).times { @asm.add(:l, @asm.d(6), @asm.d(6)) }
            @asm.lea(@asm.abs_l(place, Runtime::Lists::HEADER), @asm.a(into))
            @asm.lea(@asm.idx(into, 0, 6), @asm.a(into))
          end

          # The runtime's list routine +routine+ on the list +node+ names, the list's place first.
          def list_call(routine, node, *args) = runtime_call(routine, [Build.int(list_place(node)), *args])

          def list_place(node)
            @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }.first
          end

          # Reference#exec_table_get: an index out of range made safe — a table whose length is a
          # power of two wraps it (what an angle wants), any other holds it to the ends. The entry is
          # read through the table's address and the index scaled to the entry's size.
          def value_of_table_get(node)
            table = @tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            count = table.values.length
            safe = if count.positive? && (count & (count - 1)).zero?
                     Build.binop(:&, node.index, Build.int(count - 1))
                   else
                     Build.clamped(node.index, Build.int(0), Build.int(count - 1))
                   end
            bytes, signed = table_keeping(table)
            value(safe)
            @asm.lea(@asm.abs_l(table_label(table.name)), @asm.a(0))
            emit_table_entry(bytes, signed)
          end

          # D0 the entry the index in D0 names in the table A0 points at, widened by its size and sign.
          def emit_table_entry(bytes, signed)
            case bytes
            when 1
              @asm.move(:b, @asm.idx(0, 0, 0), @asm.d(0))
              return @asm.and(:l, @asm.imm(0xFF), @asm.d(0)) unless signed

              @asm.ext(:w, @asm.d(0))
              @asm.ext(:l, @asm.d(0))
            when 2
              @asm.lsl(:l, 1, @asm.d(0))
              @asm.move(:w, @asm.idx(0, 0, 0), @asm.d(0))
              signed ? @asm.ext(:l, @asm.d(0)) : @asm.and(:l, @asm.imm(0xFFFF), @asm.d(0))
            else
              @asm.lsl(:l, 2, @asm.d(0))
              @asm.move(:l, @asm.idx(0, 0, 0), @asm.d(0))
            end
          end

          # --- timers ---
          #
          # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
          # doing, and runs what the game said to do on each tick. A frame is the interpreter's
          # sixtieth of a second, so at every frame boundary a running timer gains its rate in
          # sixtieths of a tick, and each whole tick that comes to is a tick (Reference#accrue_timer).
          # Each timer keeps when it was first started (nought for never), since timers move on in the
          # order they were first started; whether it is running; its rate as whole ticks and
          # sixtieths a frame; the sixtieths of a tick it is through; and its whole ticks, coming
          # round at 65536 as the interpreter's count does.

          TIMER_NUMBERS = %i[order running whole_rate part_rate parts ticks].freeze
          FRAMES_A_SECOND = Reference::FRAME_RATE

          def keep_timer_numbers
            return if @timers.empty?

            @timer_numbers = @timers.values.to_h { |number| [number, TIMER_NUMBERS.to_h { |what| [what, keep_local(:"timer#{number}_#{what}")] }] }
            @timers_started = keep_local(:timers_started)
            @timer_crossed = keep_local(:timer_crossed)
          end

          def timer_number(name, what) = @timer_numbers.fetch(@timers.fetch(name)).fetch(what)

          # Reference#exec_timer_start: running at its rate, its count from nought — and, the first
          # time, given its place in the order the timers move on in.
          def emit_timer_start(node)
            order = timer_number(node.name, :order)
            started = fresh("started_before")
            jump_unless(Build.binop(:==, Build.var_ref(order), Build.int(0)), started)
            emit_sum(@timers_started, :+, Build.int(1))
            value(@timers_started)
            store(order)
            @asm.label(started)
            whole, part = node.hz.divmod(FRAMES_A_SECOND)
            { running: 1, whole_rate: whole, part_rate: part, parts: 0, ticks: 0 }.each do |what, number|
              store_number(timer_number(node.name, what), number)
            end
          end

          # Reference#exec_timer_stop: its count is kept.
          def emit_timer_stop(node) = store_number(timer_number(node.name, :running), 0)

          # Reference#timer_ticks: nought for a timer never started, which is what its count starts at.
          def value_of_timer_ticks(node) = value(timer_number(node.name, :ticks))

          # THE ROUTINES THE RUNTIME RUNS AT EACH FRAME BOUNDARY: one that moves every running timer
          # on, in the order the timers were first started, and one for each timer, which moves it on
          # and runs its handler. None for a game with no timers.
          def timer_sections
            return [] if @timers.empty?

            each_timer = @timers.flat_map { |name, _| timer_section(name) }
            @frame_begins = "timers frame"
            in_order = routine_section(@frame_begins, [], routine: "the timers") do
              (1..@timers.size).each do |place_in_order|
                @timers.each_key do |name|
                  skip = fresh("not_this_one")
                  jump_unless(Build.binop(:==, Build.var_ref(timer_number(name, :order)), Build.int(place_in_order)), skip)
                  jump_unless(Build.var_ref(timer_number(name, :running)), skip)
                  call_routine(timer_label(name))
                  @asm.label(skip)
                end
              end
            end
            [*each_timer, in_order]
          end

          def timer_label(name) = "timer #{name} frame"

          # One timer, a frame on: its sixtieths, the whole ticks they come to, and its handler run
          # once for each. How many that is is settled before the first of them runs, so a handler
          # that stops or restarts its own timer still finishes the ticks this frame crossed. A
          # handler too big for a branch is cut into parts as a routine is (RoutineCuts).
          def timer_section(name)
            parts = timer_number(name, :parts)
            ticks = timer_number(name, :ticks)
            sixtieths = Build.binop(:+, Build.var_ref(parts), Build.var_ref(timer_number(name, :part_rate)))
            rate = Build.int(FRAMES_A_SECOND)
            handler = @tick_handlers[name]
            body, cut = handler ? @cuts.fit(timer_label(name), handler.children) : [[], []]
            routine = "timer #{name.inspect}"
            each_tick = routine_section(timer_label(name), [], routine: routine) do
              value(Build.binop(:+, Build.var_ref(timer_number(name, :whole_rate)), Build.binop(:/, sixtieths, rate)))
              store(@timer_crossed)
              value(Build.binop(:%, sixtieths, rate))
              store(parts)
              value(Build.binop(:&, Build.binop(:+, Build.var_ref(ticks), Build.var_ref(@timer_crossed)), Build.int(0xFFFF)))
              store(ticks)
              if handler
                top = fresh("tick")
                done = fresh("ticks_done")
                @asm.label(top)
                jump_unless(Build.binop(:>, Build.var_ref(@timer_crossed), Build.int(0)), done)
                body.each { |child| statement(child) }
                emit_sum(@timer_crossed, :-, Build.int(1))
                @asm.bra(top)
                @asm.label(done)
              end
            end
            [each_tick, *@cuts.part_sections(cut) { |part, statements| routine_section(part, statements, routine: routine) }]
          end

          # --- tests: jump unless one holds ---

          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.bra(label) if known

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            @asm.bra(label)
            @asm.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on the flags it leaves, without
          # making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.bra(label) if known.zero?) if known

            if binop?(condition, :and)
              # The interpreter works both sides out; the second is skipped here when the first does
              # not hold, which is the same thing, since working a side out changes nothing.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif condition.is_a?(Node) && condition.kind == :binop && COMPARISONS.include?(condition.op)
              emit_compare(condition)
              @asm.branch(FAILS_WHEN.fetch(condition.op), label)
            else
              value(condition)
              @asm.tst(:l, @asm.d(0))
              @asm.branch(:eq, label)
            end
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          # The two sides of a comparison compared: the left side's flags against the right (CMP),
          # which the branch that follows reads.
          def emit_compare(node)
            with_right_operand(node.lhs, node.rhs) { |right| @asm.cmp(:l, right, @asm.d(0)) }
          end

          # --- values: each leaves its number in D0 ---

          # A value the lowering makes for itself beside the IR's: where a label is.
          LabelAddress = Data.define(:label)

          def value(operand)
            known = folded(operand)
            return load_constant(known) if known

            case operand
            when Symbol then load_variable(operand)
            when Node then send(VALUES.fetch(operand.kind), operand)
            when LabelAddress then @asm.move(:l, @asm.imm(operand.label), @asm.d(0))
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def value_of_int(node) = load_constant(node.value)

          # This build reads the first pad only, so one player is connected, always.
          def value_of_players_connected(_node) = load_constant(1)

          # A cartridge is played by one person, the first player.
          def value_of_local_player(_node) = load_constant(1)
          def value_of_var_ref(node) = load_variable(node.name)

          # One byte of a named blob of data, which the game says where to look in as it is built, so it is a number
          # here (Reference#data_byte).
          def value_of_data_byte(node)
            bytes = by_kind(:data).fetch(node.name) { raise LoweringError, "reference to undefined data #{node.name.inspect}" }.bytes
            byte = bytes.getbyte(node.index) or raise LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}"
            load_constant(byte)
          end

          # Int32.mul_fix and Int32.div_fix: a call, with the count of the fraction's bits.
          def value_of_mul_fix(node) = runtime_call("rt_mul_fix", [node.lhs, node.rhs, Build.int(fraction_bits(node))])
          def value_of_div_fix(node) = runtime_call("rt_div_fix", [node.lhs, node.rhs, Build.int(fraction_bits(node))])

          # The bits of fraction a number has, 0 to 32, which is as many as the routines' registers can bring up.
          def fraction_bits(node)
            bits = node.fraction_bits
            return bits if bits.between?(0, 32)

            raise LoweringError, "a number with #{bits} bits of fraction is more than the Genesis build can work " \
                                 "out. It can work out 0 to 32."
          end

          def value_of_binop(node)
            return value_of_comparison(node) if COMPARISONS.include?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)
            return if %i[<< >>].include?(node.op) && emit_shift_by_number(node)
            return if node.op == :* && emit_product_by_power_of_two(node)
            return if node.op == :/ && emit_divide_by_number(node)
            return if node.op == :% && emit_remainder_by_number(node)

            return runtime_call(CALLED_SUMS.fetch(node.op), [node.lhs, node.rhs]) if CALLED_SUMS.key?(node.op)

            op = IN_PLACE_SUMS.fetch(node.op)
            with_right_operand(node.lhs, node.rhs) do |right|
              if op == :eor && right.mode != :dn && right.mode != :imm
                @asm.move(:l, right, @asm.d(1))
                right = @asm.d(1)
              end
              @asm.public_send(op, :l, right, @asm.d(0))
            end
          end

          # A comparison as a 1 when it holds and a 0 when it does not.
          def value_of_comparison(node)
            emit_compare(node)
            @asm.scc(HOLDS_WHEN.fetch(node.op), @asm.d(0))
            @asm.and(:l, @asm.imm(1), @asm.d(0))
          end

          # `and` and `or` work both sides out, as the interpreter does, and give a 1 or a 0.
          def value_of_both_or_either(node)
            push_value(node.rhs)
            value(node.lhs)
            @asm.tst(:l, @asm.d(0))
            @asm.scc(:ne, @asm.d(0))
            @asm.move(:l, @asm.post(M68000::SP), @asm.d(1))
            @asm.tst(:l, @asm.d(1))
            @asm.scc(:ne, @asm.d(1))
            @asm.public_send(node.op == :and ? :and : :or, :l, @asm.d(1), @asm.d(0))
            @asm.and(:l, @asm.imm(1), @asm.d(0))
          end

          def value_of_neg(node)
            value(node.operand)
            @asm.neg(:l, @asm.d(0))
          end

          def value_of_bit_not(node)
            value(node.operand)
            @asm.not(:l, @asm.d(0))
          end

          def value_of_absolute(node)
            done = fresh("positive")
            value(node.operand)
            @asm.tst(:l, @asm.d(0))
            @asm.branch(:pl, done)
            @asm.neg(:l, @asm.d(0))
            @asm.label(done)
          end

          # Reference#clamp_value: held at the floor, then at the ceiling.
          def value_of_clamped(node)
            value(node.operand)
            [[node.min, :ge], [node.max, :le]].each do |bound, stays|
              right = operand_of(bound)
              unless right
                @asm.move(:l, @asm.d(0), @asm.pre(M68000::SP))
                value(bound)
                @asm.move(:l, @asm.d(0), @asm.d(1))
                @asm.move(:l, @asm.post(M68000::SP), @asm.d(0))
                right = @asm.d(1)
              end
              within = fresh("within")
              @asm.cmp(:l, right, @asm.d(0))
              @asm.branch(stays, within)
              @asm.move(:l, right, @asm.d(0))
              @asm.label(within)
            end
          end

          # A shift right by a number written in the program is one instruction; any other count is
          # the runtime's shift.
          def value_of_shift_right(node)
            return if node.bits.is_a?(Integer) && node.bits.between?(0, 31) && emit_shift(node.operand, :asr, node.bits)

            runtime_call("rt_shr32", [node.operand, Build.int(node.bits)])
          end

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # The buttons held, or pressed, through the pass: a bit each, in IR::Buttons's order, and
          # any of them for Buttons::ANY.
          def value_of_held(node) = emit_button_truth(Runtime::Frame::HELD, node.button)
          def value_of_pressed(node) = emit_button_truth(Runtime::Frame::PRESSED, node.button)

          def emit_button_truth(which, button)
            mask = if button == Buttons::ANY
                     Buttons.mask(Console::GENESIS.buttons)
                   else
                     1 << (Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}")
                   end
            @asm.move(:w, runtime_at(which), @asm.d(0))
            @asm.and(:w, @asm.imm(mask), @asm.d(0))
            @asm.scc(:ne, @asm.d(0))
            @asm.and(:l, @asm.imm(1), @asm.d(0))
          end

          def load_variable(name) = @asm.move(:l, var(name), @asm.d(0))

          def load_constant(number)
            number = Int32.wrap(number)
            return @asm.moveq(number, @asm.d(0)) if number.between?(-128, 127)

            @asm.move(:l, @asm.imm(number), @asm.d(0))
          end

          def folded(node) = @plan.folded(node)

          def variable_named(node)
            return node if node.is_a?(Symbol)

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # Where +node+ can be read as the right-hand side of an instruction without working
          # anything out: the number itself for one written in the program, the variable's place for
          # a variable; or nil.
          def operand_of(node)
            known = folded(node)
            return @asm.imm(known) if known

            name = variable_named(node)
            var(name) if name
          end

          # The left side worked out into D0, and the block handed where the right side is: in place
          # when it needs nothing worked out, and otherwise worked out first, pushed, and pulled into
          # D1 once the left side is in D0.
          def with_right_operand(left, right)
            operand = operand_of(right)
            if operand
              value(left)
              return yield(operand)
            end

            push_value(right)
            value(left)
            @asm.move(:l, @asm.post(M68000::SP), @asm.d(1))
            yield @asm.d(1)
          end

          # The number +node+ worked out into D0 and pushed.
          def push_value(node)
            value(node)
            @asm.move(:l, @asm.d(0), @asm.pre(M68000::SP))
          end

          # A product by a power of two written in the program, as a shift — none at all for a product
          # by one. True when it was done so.
          def emit_product_by_power_of_two(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              number = folded(by)
              next unless number&.positive? && (number & (number - 1)).zero? && number <= (1 << 30)

              return emit_shift(other, :lsl, number.bit_length - 1)
            end
            false
          end

          # `<<` and `>>` by a number written in the program, in range: one shift. True when done so.
          def emit_shift_by_number(node)
            count = folded(node.rhs)
            return false unless count&.between?(0, 31)

            emit_shift(node.lhs, node.op == :<< ? :lsl : :asr, count)
          end

          # +operand+ worked out and shifted by +count+ places (#emit_shift_of_d0). True.
          def emit_shift(operand, how, count)
            value(operand)
            emit_shift_of_d0(how, count)
            true
          end

          # D0 shifted by +count+ places, 0 to 31: one instruction up to 8, and the count put in a
          # register beyond.
          def emit_shift_of_d0(how, count)
            if count.between?(1, 8)
              @asm.public_send(how, :l, count, @asm.d(0))
            elsif count > 8
              @asm.moveq(count, @asm.d(1))
              @asm.public_send(how, :l, @asm.d(1), @asm.d(0))
            end
          end

          # A runtime routine taking +args+ in D0, D1, D2... Each that needs working out is worked out
          # in order and pushed, then they are pulled into their registers, the last first; then the
          # ones that are only a number or a variable are put in theirs.
          def runtime_call(name, args)
            worked = args.each_index.reject { |i| simple_operand(args[i]) }
            worked.each { |i| push_value(args[i]) }
            worked.reverse_each { |i| @asm.move(:l, @asm.post(M68000::SP), @asm.d(i)) }
            args.each_with_index do |arg, i|
              next if worked.include?(i)

              source = simple_operand(arg)
              if source.mode == :imm && source.value.is_a?(Integer) && source.value.between?(-128, 127)
                @asm.moveq(source.value, @asm.d(i))
              else
                @asm.move(:l, source, @asm.d(i))
              end
            end
            call_routine(name)
          end

          # Where an argument to a runtime routine can be read without working anything out: a number,
          # a variable, or the address of a label.
          def simple_operand(arg)
            return @asm.imm(arg.label) if arg.is_a?(LabelAddress)

            operand_of(arg)
          end
        end
      end
    end
  end
end
