# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        # ONE PROGRAM, LOWERED STRAIGHT TO R3000 MACHINE CODE: the PlayStation's peer of the Genesis's,
        # Super Nintendo's and Color's lowerings. It walks the IR with a table naming the method for each
        # kind of statement and each kind of value (the interpreter's own shape, Reference), and emits the
        # instructions through the assembler (R3000), calling the runtime (PS1::Runtime) for what is too
        # long to write in place.
        #
        # HOW A NUMBER IS WORKED OUT. Every value leaves its answer in v0, a register of 32 bits as a
        # game's numbers are. A sum of two works the left-hand side out into v0 and the right-hand side
        # into v1 — straight from where it is when it is a number written in the program or a variable,
        # and otherwise worked out first, pushed on the stack, and pulled into v1 once the left-hand side
        # is in v0 — and one instruction puts the answer in v0. A side worked out while another waits
        # keeps the waiting one in a saved register (#emit_keep_temporary). Adding and subtracting are
        # ADDU and SUBU, which wrap as IR::Int32 does and never stop the processor (ADD would). A runtime
        # routine taking several numbers has them in Runtime::ARGUMENTS. Nothing is kept in a register
        # from one statement to the next, but a variable read by the very instruction after the store
        # that set it (#emit_load_variable), so a statement never has to know what came before it.
        #
        # WHERE THINGS LIVE. The game's variables, and each routine's own numbers — a loop's count, a
        # `case`'s reading — are places fixed while the program is built, in the scratchpad while it has
        # room and in the game's region of RAM after (Memory), so a routine cannot call itself, and a
        # program in which one can is refused. Every place is named as a distance from fp (the
        # scratchpad) or gp (the region). Every routine is called with JAL and keeps its return address
        # on the stack, since it may call others.
        #
        # It makes the kinds in its two tables, and refuses by name a program that reaches one it does
        # not make yet (NOT_LOWERED_YET), and one a PlayStation cannot do at all in the words its
        # answers have (Console::Answers#refusals).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the +part+
          # of the build that is missing ("the picture"), for a test run to count skips by.
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          include ControlFlow

          # EVERY KIND THIS LOWERING WRITES: its own, each by a method called by name in
          # #emit_statement and #value_of_kind, and each part's (Paint, Faces, and the loops and tests
          # every cartridge lowering shares, ControlFlow), which each part writes in a case of its own.
          # A declaration writes nothing where it is. Read by test_ps1_kind_coverage.rb.
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp call call_one_of
            halt wait_vblank list_new list_push list_drop list_set list_fill list_copy list_sort
            timer_start timer_stop on_timer show_light_now rumble
          ] + ControlFlow::STATEMENT_KINDS + Paint::STATEMENT_KINDS + Faces::STATEMENT_KINDS +
            Nodes.of_role(:declaration)).freeze

          def emit_statement(node)
            case node.kind
            when :program then emit_children(node)
            when :set then emit_set(node)
            when :add then emit_add(node)
            when :sub then emit_sub(node)
            when :copy then emit_copy(node)
            when :negate then emit_negate(node)
            when :abs then emit_abs(node)
            when :negate_abs then emit_negate_abs(node)
            when :clamp then emit_clamp(node)
            when *ControlFlow::STATEMENT_KINDS then emit_control_flow_statement(node)
            when :call then emit_call(node)
            when :call_one_of then emit_call_one_of(node)
            when :halt then emit_halt(node)
            when :wait_vblank then emit_wait_vblank(node)
            when :list_new then emit_list_new(node)
            when :list_push then emit_list_push(node)
            when :list_drop then emit_list_drop(node)
            when :list_set then emit_list_set(node)
            when :list_fill then emit_list_fill(node)
            when :list_copy then emit_list_copy(node)
            when :list_sort then emit_list_sort(node)
            when :timer_start then emit_timer_start(node)
            when :timer_stop then emit_timer_stop(node)
            # a timer's handler runs as its timer ticks, not where it is written
            when :on_timer then emit_nothing(node)
            # no light is made on a PlayStation yet, and a game without one works nothing out again
            when :show_light_now then emit_nothing(node)
            # the build reads a digital pad, which has no motor: nothing is felt
            when :rumble then emit_nothing(node)
            when *Paint::STATEMENT_KINDS then emit_paint_statement(node)
            when *Faces::STATEMENT_KINDS then emit_faces_statement(node)
            else emit_declaration_or_refuse(node)
            end
          end

          # A declaration is gathered before the program is written, so it writes nothing where it
          # is; any other kind with no writer is a mistake in this file.
          def emit_declaration_or_refuse(node)
            return emit_nothing(node) if Nodes.of_role(:declaration).include?(node.kind)

            raise LoweringError, "no writer here for #{node.kind.inspect}"
          end

          VALUE_KINDS = %i[
            int var_ref binop neg bit_not absolute clamped shift_right held pressed list_get list_len
            table_get timer_ticks chance data_byte players_connected local_player mul_fix div_fix
          ].freeze

          def value_of_kind(node)
            case node.kind
            when :int then value_of_int(node)
            when :var_ref then value_of_var_ref(node)
            when :binop then value_of_binop(node)
            when :neg then value_of_neg(node)
            when :bit_not then value_of_bit_not(node)
            when :absolute then value_of_absolute(node)
            when :clamped then value_of_clamped(node)
            when :shift_right then value_of_shift_right(node)
            when :held then value_of_held(node)
            when :pressed then value_of_pressed(node)
            when :list_get then value_of_list_get(node)
            when :list_len then value_of_list_len(node)
            when :table_get then value_of_table_get(node)
            when :timer_ticks then value_of_timer_ticks(node)
            when :chance then value_of_chance(node)
            when :data_byte then value_of_data_byte(node)
            when :players_connected then value_of_players_connected(node)
            when :local_player then value_of_local_player(node)
            when :mul_fix then value_of_mul_fix(node)
            when :div_fix then value_of_div_fix(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list the day
          # the PlayStation does it; test_ps1_kind_coverage.rb holds the list and the kind lists above to every
          # kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({
                                                    "the painted (bitmap) screen" => %i[draw_column_at save_region restore_region camera],
                                                    "fades, lights and screen effects" => %i[fade tint pixelate shade_outside],
                                                    "sprites and tiled backgrounds" => %i[background scroll_background set_tile show_map
                                                                                          present_objects color_list_holds background_colors
                                                                                          hide_sprites place_bar copy_tiles box_background
                                                                                          copy_owed_tiles load_sprite_tiles affine_background
                                                                                          scroll_rows see_through show_held_tiles
                                                                                          show_picture_group pixels_overlap],
                                                    "sound" => %i[enable_sound beep noise wave stop_wave play_song stop_music
                                                                  hold_music play_from_list play_sound_effect play_sample stop_sample],
                                                    "save memory" => %i[save_init save_store save_write save_erase save_read save_sum
                                                                        save_load_list save_store_list]
                                                  })

          # Where a list went: the address of its header, how many items it holds, the bytes of a slot,
          # and its name. Read back as the four-part row every cartridge console's reader takes
          # (CartridgeHeadlessRun#read_lists), through #to_a.
          ListPlace = Data.define(:address, :capacity, :slot_bytes, :name) do
            def to_a = [address, capacity, slot_bytes, name]
          end

          # The parts a game can need that the build does not make yet and that are no kind of step of
          # their own, so NOT_LOWERED_YET cannot name them (#refuse_unmade_parts!): a backdrop of a colour
          # (the build shows black where nothing is drawn), the second pad (the build reads the first), and
          # a game that paints and also shows a screen drawn from tiles.
          BACKDROP_COLOUR = "a backdrop colour"
          SECOND_PAD = "the second pad"
          TILED_SCREEN = "sprites and tiled backgrounds"

          # The runtime's routines for a binop worked out by a call.
          CALLED_SUMS = Ractor.make_shareable({ :/ => "rt_div32", :% => "rt_mod32", :<< => "rt_shl32", :>> => "rt_shr32" })
          # The binops that are one instruction on two registers, and their forms with a number written in
          # the instruction (none for SUBU: a subtraction of a number is an addition of its negative).
          IN_PLACE_SUMS = Ractor.make_shareable({ :+ => :addu, :- => :subu, :& => :and, :| => :or, :^ => :xor })
          IMMEDIATE_SUMS = Ractor.make_shareable({ :+ => :addiu, :& => :andi, :| => :ori, :^ => :xori })
          COMPARISONS = %i[< <= > >= == !=].freeze

          # What the game's code is to the author, for a program too big for the console's memory.
          TABLES_HOLDING = R3000::Holding.new(what: "the game's tables", fix: "make its tables shorter, or use fewer of them")
          ROUTINES_HOLDING = R3000::Holding.new(what: "the game's routines", fix: "make its routines shorter, or use fewer of them")

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          # The console this lowers for (BuildCache).
          CONSOLE = Console::PLAYSTATION

          # What the build works out once for every try (BuildCache#facts). The PlayStation's build makes
          # one try, so there is nothing of its own to keep.
          class BuildFacts
            def initialize(_cache); end
          end

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # Where each of the game's variables went, by its name, and each of its lists — [its place, its
          # capacity, the bytes a slot, its name] — once #sections has placed them; and the label of the
          # routine the runtime runs at each frame boundary, or nil for a game with no timers. And each
          # section of the game's own routines, by its name, to what that routine is to the author ("scene
          # :title", "the game loop"), for a profile naming where a frame went.
          attr_reader :variables, :lists, :frame_begins, :section_routines

          include Paint
          include Faces

          def initialize(program, memory:, cache: BuildCache.for(PS1, program))
            @program = program
            @memory = memory
            @cache = cache
            @plan = cache.plan
            @funcs = @plan.funcs
            @tick_handlers = @plan.tick_handlers
            @timers = @plan.timers
            @called = @plan.called
            @declared_lists = @plan.declared_lists
            @tables = @plan.tables
            @handover = @plan.handover
            @scenes = @plan.scenes
            @lists = {}
            @lists_dropped_from_front = program.walk.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }.uniq
            @lists_of_fixed_length = lists_of_fixed_length(program)
            @variables = {}
            @locals = {}
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @section_routines = {}
          end

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and the
          # program itself.
          def sections
            Backends.refuse_start_file_on_cartridge!(@program, @plan.console, LoweringError)
            @plan.refuse_hardware_only_kinds!
            @plan.refuse_kinds_not_made_yet!(NOT_LOWERED_YET, NotMadeYet)
            @plan.refuse_unmade_followed_lists!(NotMadeYet)
            @plan.refuse_routines_that_call_themselves!
            @plan.refuse_what_console_lacks!
            refuse_unmade_parts!
            variables_most_read_first.each do |name|
              @variables[name] = @memory.reserve_scratchpad("the variable #{name.inspect}", 4)
            end
            @declared_lists.each_value do |node|
              width = LoweringPlan::SLOT_BYTES.fetch(node.width)
              place = if node.name == corners_list_in_face
                        runtime_place(Runtime::Faces::FACE) + Runtime::Faces::CORNERS_LIST_OFFSET_BYTES
                      else
                        @memory.reserve("the list #{node.name.inspect}", Runtime::Lists::HEADER + (node.capacity * width))
                      end
              @lists[node.name] = ListPlace.new(address: place, capacity: node.capacity, slot_bytes: width, name: node.name.to_s)
            end
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            keep_loop_running
            routines = @called.map do |name|
              routine_section(self.class.routine_label(name), @funcs.fetch(name).children, routine: @plan.routine_said(name))
            end
            timers = timer_sections
            main = routine_section(MAIN, @program.children, routine: "the game loop")
            # The pictures are known once every routine is made, so their tables come last.
            [data_section, *table_sections, *routines, *timers, main, *paint_sections, *face_sections]
          end

          private

          # A backdrop of a colour (`screen ..., backdrop:`, or a list of colours the backdrop follows), and
          # the second pad (`players:` more than 1, or `player: 2` and on), refused as not made yet.
          def refuse_unmade_parts!
            # A painted screen's backdrop is black whatever its `screen` names (SceneHandover#backdrop_of),
            # so only a screen drawn from tiles shows one.
            backdrop = @program.walk.any? do |node|
              (tiles_screen?(node) && !node.backdrop.to_i.zero?) || (node.kind == :color_list && node.backdrop_place)
            end
            refuse_unmade!(BACKDROP_COLOUR, "shows a backdrop colour where nothing is drawn") if backdrop
            # Handing over between a painted screen and one drawn from tiles wipes the picture
            # (SceneHandover.crossing?), which is made with the screens drawn from tiles.
            if @program.walk.any? { |node| tiles_screen?(node) } &&
               @program.walk.any? { |node| node.kind != :screen && Paint::STATEMENT_KINDS.include?(node.kind) }
              refuse_unmade!(TILED_SCREEN, "paints a picture and also shows a screen drawn from tiles")
            end
            second_pad = @program.most_players.to_i > 1 || @program.walk.any? do |node|
              %i[held pressed].include?(node.kind) && node.player.is_a?(Integer) && node.player > 1
            end
            refuse_unmade!(SECOND_PAD, "reads the second pad") if second_pad
          end

          def tiles_screen?(node)
            node.kind == :screen && SceneHandover::DISPLAYS.key?(node.mode) && SceneHandover.tiles?(node.mode)
          end

          def refuse_unmade!(part, what)
            raise NotMadeYet.new("This game #{what}. The #{CONSOLE.title} build does not make that yet. To fix this, " \
                                 "build the game for the Game Boy Advance alone for now (`consoles: %i[gba]`).", part: part)
          end

          # The variables the game loops keep of their own, in the console's order (IR::Frames::ConsoleLoop).
          def loop_variables = @plan.game_loops.flat_map { |node| console_loop(node).variables }

          # Every variable the program keeps, those its code reads in the most places first, so the
          # scratchpad (Memory#reserve_scratchpad) goes to the ones read most. Read in more places is not
          # read more often, but the numbers a drawing's or a loop's every step reads are read all
          # through it, and a variable set once and shown is read in one.
          def variables_most_read_first
            reads = Hash.new(0)
            @program.walk.each { |node| reads[node.name] += 1 if node.kind == :var_ref }
            (Reach.variables(@program) | loop_variables).each_with_index.sort_by { |name, at| [-reads[name], at] }.map(&:first)
          end

          # --- the data ---

          # The places that do not start at nought (each an address and a number, a word each, and an
          # address of nought after the last), each list's address, capacity and slot (the runtime's start
          # reads them), and the tables of routines a call picks from by number.
          def data_section
            asm = R3000.new("game data", holds: TABLES_HOLDING)
            asm.label("game_starts")
            @starts.each { |address, value| asm.data_words(address, value) }
            asm.data_words(0)
            asm.label("game_lists")
            @lists.each_value do |list|
              asm.data_words(list.address)
              asm.data_halves(list.capacity, list.slot_bytes.bit_length - 1)
            end
            asm.data_words(0)
            @routine_tables.each do |targets, label|
              asm.label(label)
              asm.data_words(targets.map { |name| self.class.routine_label(name) })
            end
            asm.section
          end

          # Each table a run reads, in a section of its own: its entries as the program keeps them
          # (LoweringPlan#table_keeping), the low byte first.
          def table_sections
            @plan.tables_read.map do |table|
              bytes = Runtime::Lists::EntryKeeping.of(@plan.table_keeping(table)).bytes
              asm = R3000.new(table_label(table.name), holds: TABLES_HOLDING)
              asm.label(table_label(table.name))
              asm.data_bytes(table.values.flat_map { |entry| Array.new(bytes) { |i| (Int32.wrap(entry) >> (8 * i)) & 0xFF } })
              asm.section
            end
          end

          def table_label(name) = "table #{name}"

          # --- routines ---

          # A routine of +body+'s statements, or of what the block emits for one this lowering makes for
          # itself. Its return address is kept on the stack for its whole length, since what it calls
          # changes ra. +routine+ is what it is to the author.
          def routine_section(label, body, routine:)
            @section_routines[label] = routine
            @asm = R3000.new(label, holds: ROUTINES_HOLDING)
            @stored = nil
            @index_faults = {}
            @routine = label
            @routine_words = routine
            @labels = 0
            @asm.label(label)
            emit_push(:ra)
            body.each { |node| statement(node) }
            yield if block_given?
            emit_pop(:ra)
            @asm.jr(:ra)
            emit_index_faults
            @asm.section
          end

          # A label no other in the routine has: +what+ and the count, apart.
          def fresh_label(what)
            @labels += 1
            "#{@routine}.#{what}##{@labels}"
          end

          # A number of the routine's own, kept in RAM, by a name of its own that a value can read as a
          # variable. +start+ is what it holds from power-on.
          def keep_local(what, start: 0)
            name = DerivedNames.local_number_name(@routine, what, @locals.length + 1)
            @locals[name] = @memory.reserve_scratchpad("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          # Where the variable +name+ (or a number of a routine's own) is kept, as an address.
          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # [distance, register] that names +address+ in a load or a store: a distance from fp for a place
          # in the scratchpad, from gp where it reaches, and otherwise from `at`, given the top half of the
          # address first.
          def base_and_distance(address)
            fast = Memory.distance_from_scratchpad(address)
            return [fast, :fp] if fast

            distance = Memory.distance_from_base(address)
            return [distance, :gp] if distance

            high = ((address + 0x8000) >> 16) & 0xFFFF
            @asm.lui(:at, high)
            [Int32.wrap(address - (high << 16)), :at]
          end

          def emit_load_word(register, address) = @asm.lw(register, *base_and_distance(address))
          def emit_store_word(register, address) = @asm.sw(register, *base_and_distance(address))

          # A variable read straight after it was stored is taken from the register it was stored from, with
          # no load: a load from main RAM waits several cycles, and a statement that sets a variable is
          # often followed by one that reads it (`set base`, then a table read at `base`). Only straight
          # after, with no label between, so no other way into the code can arrive with the register
          # holding something else.
          def emit_load_variable(name, register = :v0)
            name_stored, from, at = @stored
            if name_stored == name && at == @asm.here && !@asm.labelled_here?
              @asm.move(register, from) unless register == from
              return
            end

            emit_load_word(register, place_of(name))
          end

          def emit_store(name, register = :v0)
            emit_store_word(register, place_of(name))
            @stored = [name, register, @asm.here]
          end

          def runtime_place(name) = @memory[name]

          def emit_push(register)
            @asm.addiu(:sp, :sp, -4)
            @asm.sw(register, 0, :sp)
          end

          def emit_pop(register)
            @asm.lw(register, 0, :sp)
            @asm.addiu(:sp, :sp, 4)
          end

          # WHERE A VALUE WAITS WHILE THE NEXT ONE IS WORKED OUT: the saved registers, in turn, and the stack
          # only past the last of them. A value is worked out with no call to the game's own routines, and
          # every runtime routine a value calls keeps s0 to s7 as it found them (Runtime), so a number kept
          # there is still there when it is taken back; keeping it on the stack is a store and a load of
          # main RAM. The game's routines use them unsaved, which is safe only because none is ever called
          # while a value is being worked out: rt_wait_vblank runs the timers' routines, and it is a
          # statement. Taken back last kept, first.
          TEMPORARIES = %i[s0 s1 s2 s3 s4 s5 s6 s7].freeze

          def emit_keep_temporary(register)
            @temporaries ||= []
            place = TEMPORARIES[@temporaries.length]
            place ? @asm.move(place, register) : emit_push(register)
            @temporaries.push(place)
          end

          def emit_restore_temporary(register)
            place = @temporaries.pop
            place ? @asm.move(register, place) : emit_pop(register)
          end

          def call_routine(label) = @asm.jal(label)

          # --- statements ---

          def statement(node) = emit_statement(node)

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            emit_value(node.value)
            emit_store(node.var)
          end

          def emit_store_number(name, number)
            return emit_store(name, :zero) if Int32.wrap(number).zero?

            @asm.li(:v0, Int32.wrap(number))
            emit_store(name)
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`: the variable loaded, the sum made and stored.
          def emit_sum(name, op, operand)
            emit_value(Build.binop(op, Build.var_ref(name), operand))
            emit_store(name)
          end

          def emit_copy(node)
            return if node.dest == node.src

            emit_value(node.src)
            emit_store(node.dest)
          end

          def emit_negate(node)
            emit_load_variable(node.var)
            @asm.subu(:v0, :zero, :v0)
            emit_store(node.var)
          end

          def emit_abs(node)
            emit_value(Build.absolute(Build.var_ref(node.var)))
            emit_store(node.var)
          end

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def emit_negate_abs(node)
            done = fresh_label("not_above_nought")
            emit_load_variable(node.var)
            @asm.blez(:v0, done)
            @asm.subu(:v0, :zero, :v0)
            emit_store(node.var)
            @asm.label(done)
          end

          def emit_clamp(node)
            emit_value(Build.clamped(Build.var_ref(node.var), node.min, node.max))
            emit_store(node.var)
          end

          # --- what ControlFlow asks of a lowering, in the R3000's instructions ---

          def place_label(label) = @asm.label(label)
          def jump(label) = @asm.b(label)
          def emit_store_zero(name) = emit_store_number(name, 0)
          def emit_increment(name) = emit_sum(name, :+, Build.int(1))
          # Only an `if` has another side.
          def children_of(node) = [node.children, (node.else&.children if node.kind == :if) || []]
          def loop_statements(node) = console_loop(node).each_time
          def game_loops = @plan.game_loops
          def loop_form = @plan.loop_form

          def emit_copy_variable(from, to)
            emit_load_variable(from)
            emit_store(to)
          end

          def console_loop(node) = @plan.console_loop(node)

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)

            call_routine(self.class.routine_label(node.target))
          end

          # Reference#exec_call_one_of: the number worked out once, and a number naming no routine of the
          # list — below nought or past its end — calls nothing. Compared as a number that cannot be
          # negative, -1 is the biggest there is, so one test guards both ends. The routine is reached
          # through a table of their addresses, a word each.
          def emit_call_one_of(node)
            table = @routine_tables[node.targets] ||= "routines #{@routine_tables.length + 1}"
            none = fresh_label("calls_none")
            emit_value(node.which)
            @asm.sltiu(:t0, :v0, node.targets.length)
            @asm.beq(:t0, :zero, none)
            @asm.sll(:v0, :v0, 2)
            @asm.la(:t1, table)
            @asm.addu(:t1, :t1, :v0)
            @asm.lw(:t1, 0, :t1)
            @asm.jalr(:t1)
            @asm.label(none)
          end

          # A scene taking over is remembered, so what a scene does as it arrives happens on the frame it
          # changes and not again while it stays. A scene that loads first and is handed over to has that
          # pass to itself, and its routine runs from the pass after; the scene up at power-on, which
          # nothing handed over to, runs on the first pass all the same
          # (IR::SceneHandover::Arrival#loads_first?). Before any scene, the note holds -1.
          def emit_scene(scene)
            number = @scenes.fetch(scene)
            label = self.class.routine_label(scene)
            staying = fresh_label("scene_staying")
            done = fresh_label("scene_done")
            jump_unless(Build.binop(:!=, Build.var_ref(@scene), Build.int(number)), staying)
            if @handover.arrival(scene).loads_first?
              at_power_on = keep_local(:at_power_on)
              emit_value(Build.binop(:==, Build.var_ref(@scene), Build.int(-1)))
              emit_store(at_power_on)
              emit_store_number(@scene, number)
              jump_unless(Build.var_ref(at_power_on), done)
              call_routine(label)
              @asm.b(done)
            else
              emit_store_number(@scene, number)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          # A pass that halts ends as every pass does (IR::Frames::ConsoleLoop#pass_end), as the
          # interpreter ends it (Reference#place_pass_end_before_halt).
          def emit_halt(_node)
            loops_ending_passes.each_with_index do |ending, i|
              other = fresh_label("not_this_loop")
              jump_unless(Build.binop(:==, Build.var_ref(@loop_running), Build.int(i + 1)), other)
              console_loop(ending).pass_end.each { |child| statement(child) }
              @asm.label(other)
            end
            @asm.j("rt_halt")
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame counters
          # the program can read move on, where the interpreter moves them (Reference#store_frame_counters):
          # the frames shown by every frame the pass took, and what the game catches up by held at the cap,
          # both as the runtime counted them.
          def emit_wait_vblank(_node)
            call_routine("rt_wait_vblank")
            emit_load_word(:t0, runtime_place(Runtime::Frame::FRAMES_TAKEN))
            emit_load_variable(Frames::COUNT)
            @asm.addu(:v0, :v0, :t0)
            emit_store(Frames::COUNT)
            emit_store(Frames::SEEN)
            emit_load_word(:v0, runtime_place(Runtime::Frame::STEP_TAKEN))
            emit_store(Frames::STEP)
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
          def emit_list_set(node)
            return emit_slot_write(node) unless @lists_dropped_from_front.include?(node.name)

            list_call("rt_list_set", node, node.index, node.value)
          end

          def value_of_list_get(node)
            return emit_slot_read(node) unless @lists_dropped_from_front.include?(node.name)

            list_call("rt_list_get", node, node.index)
          end

          def value_of_list_len(node) = list_call("rt_list_length", node)

          # AN ITEM OF A LIST WHOSE FIRST ITEM IS ALWAYS IN ITS FIRST SLOT, read or written in place: the
          # index checked against the list's length, as rt_list_get does (an index past the end stops the
          # game, Reference#check_list_index!), then the slot at the list's place, its header and the index
          # scaled to the slot's size. The list's place is known as the program is built, so nothing is
          # handed to a routine and no call is made: a call and its return are four instructions a read
          # and the arguments two more, and a drawing reads its lists dozens of times a face.
          def emit_slot_read(node)
            list = @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }
            emit_value(node.index)
            distance, base = emit_slot_place(list)
            @asm.load(Runtime::Lists::LOADS.fetch(list.slot_bytes), :v0, distance, base)
          end

          # The index and the value worked out in the order rt_list_set takes them (#runtime_call): the
          # index first unless it needs nothing worked out.
          def emit_slot_write(node)
            list = @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }
            if simple?(node.value)
              emit_value(node.index)
              emit_load_simple(node.value, :v1)
            elsif simple?(node.index)
              emit_value(node.value)
              @asm.move(:v1, :v0)
              emit_load_simple(node.index, :v0)
            else
              emit_value(node.index)
              emit_keep_temporary(:v0)
              emit_value(node.value)
              @asm.move(:v1, :v0)
              emit_restore_temporary(:v0)
            end
            distance, base = emit_slot_place(list)
            @asm.store(Runtime::Lists::STORES.fetch(list.slot_bytes), :v1, distance, base)
          end

          # The index in v0 checked against +list+'s length, and the slot it names put in t9: [distance,
          # register] that name the slot in a load or a store. Changes t6 to t9 and at.
          def emit_slot_place(list)
            lists = Runtime::Lists
            if @lists_of_fixed_length.include?(list.name.to_sym) && list.capacity <= 0x7FFF # SLTIU's number, sign and all
              @asm.sltiu(:t7, :v0, list.capacity)
            else
              @asm.lhu(:t6, *base_and_distance(list.address + lists::LENGTH))
              @asm.sltu(:t7, :v0, :t6)
            end
            fault = @index_faults[list.address] ||= fresh_label("index_past_end")
            @asm.beq(:t7, :zero, fault) { @asm.move(:t8, :v0) }
            shift = list.slot_bytes.bit_length - 1
            shift.zero? ? @asm.move(:t9, :v0) : @asm.sll(:t9, :v0, shift)
            distance, base = base_and_distance(list.address + lists::HEADER)
            @asm.addu(:t9, :t9, base)
            [distance, :t9]
          end

          # THE LISTS WHOSE LENGTH IS ALWAYS THEIR CAPACITY, so an index is checked against a number written
          # in the instruction rather than a length read from main RAM, which has no cache and makes the
          # processor wait for every load: a game of rooms reads its lists hundreds of times a pass. Such a
          # list is made full (`full_of:`) every time it is made, nothing pushes to it, drops from it or
          # copies a table into it, and it is made among the program's first statements, before anything
          # that could read a list runs: one read before then stops the interpreter's game (the list is not
          # made yet), and must stop this one's, which the length read from RAM, nought, does. Only these kinds
          # of statement may come first, and only when no value in them reads a list: a declaration, the
          # screen chosen, a list made, a variable set.
          STATEMENTS_BEFORE_FIXED_LISTS = Ractor.make_shareable(Set[:list_new, :screen, :set, :copy, :add, :sub,
                                                                    *Nodes.of_role(:declaration)])
          LIST_READING_VALUES = %i[list_get list_len].freeze

          def lists_of_fixed_length(program)
            changed = program.walk.filter_map { |node| node.name if %i[list_push list_drop list_copy].include?(node.kind) }
            made = program.walk.select { |node| node.kind == :list_new }.group_by(&:name)
            first = []
            program.children.each do |child|
              break unless STATEMENTS_BEFORE_FIXED_LISTS.include?(child.kind)
              break if child.walk.any? { |node| LIST_READING_VALUES.include?(node.kind) }

              first << child.name if child.kind == :list_new
            end
            made.filter_map { |name, news| name if news.all?(&:full_of) && first.include?(name) && !changed.include?(name) }
          end

          # After the routine's return, for each list it reads or writes in place, where an index past the
          # end goes: the list's place handed to the runtime's fault, the index already in t8.
          def emit_index_faults
            @index_faults.each do |address, label|
              @asm.label(label)
              @asm.li(:a0, address)
              @asm.j("rt_list_index_fault")
            end
          end

          # A run of a table's entries copied into a list: the table's place and how it keeps its entries,
          # so the runtime reads them as a run does.
          def emit_list_copy(node)
            table = @tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
            kept = Runtime::Lists::EntryKeeping.of(@plan.table_keeping(table)).number
            list_call("rt_list_copy", node, LabelAddress.new(table_label(table.name)), Build.int(kept),
                      Build.int(table.values.length), node.at, Build.int(node.count))
          end

          # Reference#exec_list_sort: the list's items put in order by the numbers the list +by+ holds at
          # them. Where neither list ever has an item taken from its front, every item stays in the slot
          # its index names, so the sort is written here with both lists' places and slot sizes known
          # (#emit_fixed_front_sort); otherwise the runtime sorts through the ring (Runtime::Lists#emit_sort).
          def emit_list_sort(node)
            keys = @lists.fetch(node.by) { raise LoweringError, "the list #{node.by.inspect} is used and never declared" }
            if [node.name, node.by].any? { |name| @lists_dropped_from_front.include?(name) }
              return list_call("rt_list_sort", node, Build.int(keys.address), Build.int(node.descending ? 1 : 0))
            end

            emit_fixed_front_sort(@lists.fetch(node.name), keys, node.descending)
          end

          # AN INSERTION SORT IN THE ROUTINE'S OWN CODE, the way a console's own games sort their sprites by
          # height: for each item after the first, its number is read once, and it moves back a slot at a
          # time past the items before it whose numbers are strictly beyond its own, each moved up a slot as
          # it is passed. So level items keep their order, and a list already in order takes one compare an
          # item: about twenty instructions. Every slot is read straight from its place (the list's address,
          # its header, and the index scaled to the slot's size), and the comparison has the sign.
          #
          # a0 is the list and a1 the numbers; t0 how many items, t1 the item being placed, t3 the place of
          # the slot it would go in, t4 the item and t5 its number, t7 and t8 the item before and its number.
          def emit_fixed_front_sort(list, keys, descending)
            lists = Runtime::Lists
            item_load = lists::LOADS.fetch(list.slot_bytes)
            item_store = lists::STORES.fetch(list.slot_bytes)
            key_load = lists::LOADS.fetch(keys.slot_bytes)
            item_shift = list.slot_bytes.bit_length - 1
            key_shift = keys.slot_bytes.bit_length - 1
            next_item = fresh_label("sort_item")
            step = fresh_label("sort_step")
            place = fresh_label("sort_place")
            done = fresh_label("sort_done")

            @asm.li(:a0, list.address)
            @asm.li(:a1, keys.address)
            @asm.lhu(:t0, lists::LENGTH, :a0)
            @asm.li(:t1, 1)
            @asm.slt(:t2, :t1, :t0)
            @asm.beq(:t2, :zero, done)
            @asm.label(next_item)
            @asm.sll(:t3, :t1, item_shift)
            @asm.addu(:t3, :t3, :a0)
            @asm.load(item_load, :t4, lists::HEADER, :t3)
            @asm.sll(:t5, :t4, key_shift)
            @asm.addu(:t5, :t5, :a1)
            @asm.load(key_load, :t5, lists::HEADER, :t5)
            @asm.label(step)
            @asm.beq(:t3, :a0, place) # the first slot: nothing before it
            @asm.load(item_load, :t7, lists::HEADER - list.slot_bytes, :t3)
            @asm.sll(:t8, :t7, key_shift)
            @asm.addu(:t8, :t8, :a1)
            @asm.load(key_load, :t8, lists::HEADER, :t8)
            # Moves back past a bigger number, or past a smaller one when the biggest comes first.
            descending ? @asm.slt(:t9, :t8, :t5) : @asm.slt(:t9, :t5, :t8)
            @asm.beq(:t9, :zero, place)
            @asm.store(item_store, :t7, lists::HEADER, :t3)
            @asm.b(step) { @asm.addiu(:t3, :t3, -list.slot_bytes) }
            @asm.label(place)
            @asm.store(item_store, :t4, lists::HEADER, :t3)
            @asm.addiu(:t1, :t1, 1)
            @asm.bne(:t1, :t0, next_item)
            @asm.label(done)
          end

          # The runtime's list routine +routine+ on the list +node+ names, the list's place first.
          def list_call(routine, node, *args) = runtime_call(routine, [Build.int(list_place(node)), *args])

          def list_place(node)
            @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }.address
          end

          # Reference#exec_table_get: an index out of range made safe — a table whose length is a power of
          # two wraps it (what an angle wants), any other holds it to the ends. The entry is read through
          # the table's address and the index scaled to the entry's size; LB and LH widen by the sign.
          def value_of_table_get(node)
            table = @tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            count = table.values.length
            safe = if LoweringPlan.index_wraps?(count)
                     Build.binop(:&, node.index, Build.int(count - 1))
                   else
                     Build.clamped(node.index, Build.int(0), Build.int(count - 1))
                   end
            keeping = Runtime::Lists::EntryKeeping.of(@plan.table_keeping(table))
            emit_value(safe)
            @asm.sll(:v0, :v0, keeping.bytes.bit_length - 1) if keeping.bytes > 1
            @asm.la(:t0, table_label(table.name))
            @asm.addu(:t0, :t0, :v0)
            @asm.load(keeping.load, :v0, 0, :t0)
          end

          # --- timers ---
          #
          # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
          # doing, and runs what the game gave it to do on each tick. A frame is the interpreter's sixtieth of
          # a second, so at every frame boundary a running timer gains its rate in sixtieths of a tick, and
          # each whole tick that comes to is a tick (Reference#accrue_timer). Each timer keeps when it was
          # first started (nought for never), since timers move on in the order they were first started;
          # whether it is running; its rate as whole ticks and sixtieths a frame; the sixtieths of a tick it
          # is through; and its whole ticks, coming round at 65536 as the interpreter's count does.

          TIMER_NUMBERS = %i[order running whole_rate part_rate parts ticks].freeze
          FRAMES_A_SECOND = Reference::FRAME_RATE

          def keep_timer_numbers
            return if @timers.empty?

            @timer_numbers = @timers.values.to_h { |number| [number, TIMER_NUMBERS.to_h { |what| [what, keep_local(:"timer#{number}_#{what}")] }] }
            @timers_started = keep_local(:timers_started)
            @timer_crossed = keep_local(:timer_crossed)
          end

          def timer_number(name, what) = @timer_numbers.fetch(@timers.fetch(name)).fetch(what)

          # Reference#exec_timer_start: running at its rate, its count from nought — and, the first time,
          # given its place in the order the timers move on in.
          def emit_timer_start(node)
            order = timer_number(node.name, :order)
            started = fresh_label("started_before")
            jump_unless(Build.binop(:==, Build.var_ref(order), Build.int(0)), started)
            emit_sum(@timers_started, :+, Build.int(1))
            emit_store(order)
            @asm.label(started)
            whole, part = node.hz.divmod(FRAMES_A_SECOND)
            { running: 1, whole_rate: whole, part_rate: part, parts: 0, ticks: 0 }.each do |what, number|
              emit_store_number(timer_number(node.name, what), number)
            end
          end

          # Reference#exec_timer_stop: its count is kept.
          def emit_timer_stop(node) = emit_store_number(timer_number(node.name, :running), 0)

          # Reference#timer_ticks: nought for a timer never started, which is what its count starts at.
          def value_of_timer_ticks(node) = emit_load_variable(timer_number(node.name, :ticks))

          # THE ROUTINES_HOLDING THE RUNTIME RUNS AT EACH FRAME BOUNDARY: one that moves every running timer on, in
          # the order the timers were first started, and one for each timer, which moves it on and runs its
          # handler. None for a game with no timers.
          def timer_sections
            return [] if @timers.empty?

            each_timer = @timers.map { |name, _| timer_section(name) }
            @frame_begins = "timers frame"
            in_order = routine_section(@frame_begins, [], routine: "the timers") do
              (1..@timers.size).each do |place_in_order|
                @timers.each_key do |name|
                  skip = fresh_label("not_this_one")
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

          # One timer, a frame on: its sixtieths, the whole ticks they come to, and its handler run once for
          # each. How many that is is settled before the first of them runs, so a handler that stops or
          # restarts its own timer still finishes the ticks this frame crossed.
          def timer_section(name)
            parts = timer_number(name, :parts)
            ticks = timer_number(name, :ticks)
            sixtieths = Build.binop(:+, Build.var_ref(parts), Build.var_ref(timer_number(name, :part_rate)))
            rate = Build.int(FRAMES_A_SECOND)
            handler = @tick_handlers[name]
            routine_section(timer_label(name), [], routine: "timer #{name.inspect}") do
              emit_value(Build.binop(:+, Build.var_ref(timer_number(name, :whole_rate)), Build.binop(:/, sixtieths, rate)))
              emit_store(@timer_crossed)
              emit_value(Build.binop(:%, sixtieths, rate))
              emit_store(parts)
              emit_value(Build.binop(:&, Build.binop(:+, Build.var_ref(ticks), Build.var_ref(@timer_crossed)), Build.int(0xFFFF)))
              emit_store(ticks)
              if handler
                top = fresh_label("tick")
                done = fresh_label("ticks_done")
                @asm.label(top)
                jump_unless(Build.binop(:>, Build.var_ref(@timer_crossed), Build.int(0)), done)
                handler.children.each { |child| statement(child) }
                emit_sum(@timer_crossed, :-, Build.int(1))
                @asm.b(top)
                @asm.label(done)
              end
            end
          end

          # --- tests: jump unless one holds ---

          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.b(label) if known

            go_on = fresh_label("holds_not")
            jump_unless(condition, go_on)
            @asm.b(label)
            @asm.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on the two sides themselves,
          # without making a 1 or a 0 of it first: BEQ and BNE for equal and not, and SLT, which sets a
          # register to 1 when one side is below the other, for the rest.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.b(label) if known.zero?) if known

            if binop?(condition, :and) && Unchanging.value?(condition.rhs) { |part| folded(part) }
              # The interpreter works both sides out (Reference#eval_binop); the second is skipped here
              # when the first does not hold only where working it out changes nothing (IR::Unchanging). A
              # side that reads a list can stop the game (an index out of range), so it is worked out
              # whatever the first side gives, by the value below.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif condition.is_a?(Node) && condition.kind == :binop && COMPARISONS.include?(condition.op)
              return if jump_unless_against_number(condition, label)

              with_right_operand(condition.lhs, condition.rhs) do
                case condition.op
                when :== then @asm.bne(:v0, :v1, label)
                when :!= then @asm.beq(:v0, :v1, label)
                when :< then jump_on_below(:v0, :v1, label, holds: false)
                when :>= then jump_on_below(:v0, :v1, label, holds: true)
                when :> then jump_on_below(:v1, :v0, label, holds: false)
                when :<= then jump_on_below(:v1, :v0, label, holds: true)
                end
              end
              # Only where working the right side out changes nothing: otherwise it may have changed
              # the variable after v0 took it.
              note_compared_variable(condition.lhs) if Unchanging.value?(condition.rhs) { |part| folded(part) }
            else
              emit_value(condition)
              @asm.beq(:v0, :zero, label)
            end
          end

          # A COMPARISON WITH A NUMBER WRITTEN IN THE PROGRAM, which the instruction can hold: against nought
          # the zero register is the other side, and below a number of 16 bits SLTI compares with it as it
          # is (above or at most one is below the next), so the number is never put in a register first.
          # The left side is in v0, as it is for any comparison. True when done so.
          def jump_unless_against_number(condition, label)
            number = folded(condition.rhs)
            return false unless number

            op = condition.op
            below = %i[> <=].include?(op) ? number + 1 : number
            return false unless %i[== !=].include?(op) ? number.zero? : below.between?(-0x8000, 0x7FFF)

            emit_value(condition.lhs)
            case op
            when :== then @asm.bne(:v0, :zero, label)
            when :!= then @asm.beq(:v0, :zero, label)
            else
              @asm.slti(:t0, :v0, below)
              # Below the number holds for < and <=, and fails for >= and >.
              %i[< <=].include?(op) ? @asm.beq(:t0, :zero, label) : @asm.bne(:t0, :zero, label)
            end
            note_compared_variable(condition.lhs)
            true
          end

          # A variable compared is still in v0 on the way past the branch, so one read straight after,
          # with no label between, is taken from there with no load (#emit_load_variable): a loop's index
          # is compared with its count and then handed to the game's variable every time round.
          def note_compared_variable(operand)
            name = operand.is_a?(Node) && operand.kind == :var_ref ? operand.name : operand
            @stored = [name, :v0, @asm.here] if name.is_a?(Symbol) || name.is_a?(String)
          end

          # Jump to +label+ when +lower+ < +higher+ is +holds+, as signed numbers.
          def jump_on_below(lower, higher, label, holds:)
            @asm.slt(:t0, lower, higher)
            holds ? @asm.bne(:t0, :zero, label) : @asm.beq(:t0, :zero, label)
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          # --- values: each leaves its number in v0 ---

          # A value the lowering makes for itself beside the IR's: where a label is.
          LabelAddress = Data.define(:label)

          def emit_value(operand)
            known = folded(operand)
            return emit_load_constant(known) if known

            case operand
            when Symbol then emit_load_variable(operand)
            when Node then value_of_kind(operand)
            when LabelAddress then @asm.la(:v0, operand.label)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def value_of_int(node) = emit_load_constant(node.value)
          def value_of_var_ref(node) = emit_load_variable(node.name)

          # This build reads the first pad only, so one player is connected, always.
          def value_of_players_connected(_node) = emit_load_constant(1)

          # A console is played by one person, the first player.
          def value_of_local_player(_node) = emit_load_constant(1)

          # One byte of a named blob of data, which the game sets where to look in as it is built, so it is
          # a number here (Reference#data_byte).
          def value_of_data_byte(node)
            data = @program.walk.find { |found| found.kind == :data && found.name == node.name }
            raise LoweringError, "reference to undefined data #{node.name.inspect}" unless data

            byte = data.bytes.getbyte(node.index) or raise LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}"
            emit_load_constant(byte)
          end

          def value_of_binop(node)
            return value_of_comparison(node) if COMPARISONS.include?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)
            return if %i[<< >>].include?(node.op) && emit_shift_by_number(node)
            return if node.op == :% && emit_remainder_by_power_of_two(node)
            return if node.op == :/ && emit_divide_by_number(node)
            return if node.op == :% && emit_remainder_by_number(node)
            return runtime_call(CALLED_SUMS.fetch(node.op), [node.lhs, node.rhs]) if CALLED_SUMS.key?(node.op)
            return if emit_sum_with_number(node)
            return if node.op == :* && emit_multiply_by_shifts(node)

            with_right_operand(node.lhs, node.rhs) do
              if node.op == :*
                @asm.mult(:v0, :v1)
                @asm.mflo(:v0)
              else
                @asm.three_registers(IN_PLACE_SUMS.fetch(node.op), :v0, :v0, :v1)
              end
            end
          end

          # Int32.mul_fix: the two numbers multiplied by MULT, which leaves all 64 bits of the product, its
          # sign included, in HI (the top half) and LO (the bottom). Brought down by the fraction's bits, the
          # answer is the 32 bits that start that many bits up: LO's top bits below HI's bottom ones. Moving
          # the whole 64 bits down keeps the sign, so a negative product too small to show is -1, rounded
          # down as the interpreter's is; and the bits above the 32 kept are dropped, so an answer too big
          # wraps as the interpreter's does.
          def value_of_mul_fix(node)
            bits = node.fraction_bits
            with_right_operand(node.lhs, node.rhs) do
              @asm.mult(:v0, :v1)
              case bits
              when 0 then @asm.mflo(:v0)
              when 32 then @asm.mfhi(:v0)
              else
                @asm.mflo(:v0)
                @asm.mfhi(:t0)
                @asm.srl(:v0, :v0, bits)
                @asm.sll(:t0, :t0, 32 - bits)
                @asm.or(:v0, :v0, :t0)
              end
            end
          end

          # Int32.div_fix: the runtime's divide of a numerator wider than 32 bits (Runtime::Int32#emit_div_fix).
          def value_of_div_fix(node) = runtime_call("rt_div_fix", [node.lhs, node.rhs, Build.int(node.fraction_bits)])

          # A sum with a number written in the program that fits in the instruction: ADDIU for adding a
          # number of 16 bits with its sign (and subtracting one, as adding its negative), ANDI, ORI and
          # XORI for one of 16 bits without. True when it was done so.
          def emit_sum_with_number(node)
            number = folded(node.rhs)
            return false unless number

            op = node.op
            if op == :-
              op = :+
              number = Int32.wrap(-number)
            end
            immediate = IMMEDIATE_SUMS[op]
            fits = op == :+ ? number.between?(-0x8000, 0x7FFF) : number.between?(0, 0xFFFF)
            return false unless immediate && fits

            emit_value(node.lhs)
            # Adding nought, or putting in or turning over no bit, leaves the number as it is.
            @asm.immediate(immediate, :v0, :v0, number) unless number.zero? && op != :&
            true
          end

          # A MULTIPLY BY A NUMBER WRITTEN IN THE PROGRAM WITH ONE OR TWO BITS SET (an index scaled by the
          # size of what it counts: 3, 6, 17), as shifts and an add. MULT leaves its answer in LO a dozen
          # cycles later, and MFLO waits for it; two shifts and an ADDU take three. The low 32 bits of
          # the product are the same either way, so it wraps as IR::Int32 has it. True when done so.
          def emit_multiply_by_shifts(node)
            number = folded(node.rhs)
            other = node.lhs
            number, other = folded(node.lhs), node.rhs unless number
            return false unless number&.between?(1, 0x7FFF_FFFF) && number.digits(2).count(1) <= 2

            low, high = (0..30).select { |bit| number[bit] == 1 }
            emit_value(other)
            @asm.sll(:t0, :v0, high) if high
            @asm.sll(:v0, :v0, low) unless low.zero?
            @asm.addu(:v0, :v0, :t0) if high
            true
          end

          # A comparison as a 1 when it holds and a 0 when it does not.
          def value_of_comparison(node)
            with_right_operand(node.lhs, node.rhs) do
              case node.op
              when :==
                @asm.xor(:v0, :v0, :v1)
                @asm.sltiu(:v0, :v0, 1)
              when :!=
                @asm.xor(:v0, :v0, :v1)
                @asm.sltu(:v0, :zero, :v0)
              when :< then @asm.slt(:v0, :v0, :v1)
              when :> then @asm.slt(:v0, :v1, :v0)
              when :<=
                @asm.slt(:v0, :v1, :v0)
                @asm.xori(:v0, :v0, 1)
              when :>=
                @asm.slt(:v0, :v0, :v1)
                @asm.xori(:v0, :v0, 1)
              end
            end
          end

          # `and` and `or` work both sides out, as the interpreter does, and give a 1 or a 0.
          def value_of_both_or_either(node)
            with_right_operand(node.lhs, node.rhs) do
              @asm.sltu(:v0, :zero, :v0)
              @asm.sltu(:v1, :zero, :v1)
              @asm.three_registers(node.op, :v0, :v0, :v1)
            end
          end

          def value_of_neg(node)
            emit_value(node.operand)
            @asm.subu(:v0, :zero, :v0)
          end

          def value_of_bit_not(node)
            emit_value(node.operand)
            @asm.nor(:v0, :v0, :zero)
          end

          # |v| with no branch: the sign spread over every bit (all ones for a negative number), XORed in and
          # taken away, which turns a negative number round and leaves the rest alone. The lowest number
          # stays itself, as Int32 has it.
          def value_of_absolute(node)
            emit_value(node.operand)
            @asm.sra(:t0, :v0, 31)
            @asm.xor(:v0, :v0, :t0)
            @asm.subu(:v0, :v0, :t0)
          end

          # Reference#clamp_value: held at the floor, then at the ceiling.
          def value_of_clamped(node)
            return if emit_clamp_from_nought(node)

            emit_value(node.operand)
            [[node.min, :floor], [node.max, :ceiling]].each do |bound, side|
              if simple?(bound)
                emit_load_simple(bound, :v1)
              else
                emit_keep_temporary(:v0)
                emit_value(bound)
                @asm.move(:v1, :v0)
                emit_restore_temporary(:v0)
              end
              within = fresh_label("within")
              side == :floor ? @asm.slt(:t0, :v0, :v1) : @asm.slt(:t0, :v1, :v0)
              @asm.beq(:t0, :zero, within)
              @asm.move(:v0, :v1)
              @asm.label(within)
            end
          end

          # A NUMBER HELD TO NOUGHT TO A CEILING WRITTEN IN THE PROGRAM, as a table's index is: one compare of
          # it as a number that cannot be negative, which a negative number fails as one too big does, and
          # only a number outside takes the rest. The sign spread over every bit is all ones below nought
          # and nought above the ceiling, so its opposite masks the ceiling down to nought or keeps it
          # whole. True when done so.
          def emit_clamp_from_nought(node)
            floor = folded(node.min)
            ceiling = folded(node.max)
            return false unless floor&.zero? && ceiling&.between?(0, 0x7FFE)

            within = fresh_label("within")
            emit_value(node.operand)
            @asm.sltiu(:t0, :v0, ceiling + 1)
            @asm.bne(:t0, :zero, within) { @asm.sra(:t0, :v0, 31) }
            @asm.nor(:t0, :t0, :zero)
            @asm.andi(:v0, :t0, ceiling)
            @asm.label(within)
            true
          end

          # A shift right by a number written in the program is one instruction; any other count is the
          # runtime's shift.
          def value_of_shift_right(node)
            if node.bits.is_a?(Integer) && node.bits.between?(0, 31)
              emit_value(node.operand)
              @asm.sra(:v0, :v0, node.bits)
              return
            end

            runtime_call("rt_shr32", [node.operand, node.bits.is_a?(Integer) ? Build.int(node.bits) : node.bits])
          end

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = emit_value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # The buttons held, or pressed, through the pass: a bit each, in IR::Buttons's order, and any of
          # them for Buttons::ANY.
          def value_of_held(node) = emit_button_down_flag(Runtime::Frame::HELD, node.button)
          def value_of_pressed(node) = emit_button_down_flag(Runtime::Frame::PRESSED, node.button)

          def emit_button_down_flag(which, button)
            mask = if button == Buttons::ANY
                     Buttons.mask(CONSOLE.buttons)
                   else
                     1 << (Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}")
                   end
            emit_load_word(:v0, runtime_place(which))
            @asm.andi(:v0, :v0, mask)
            @asm.sltu(:v0, :zero, :v0)
          end

          def emit_load_constant(number, register = :v0) = @asm.li(register, Int32.wrap(number))

          def folded(node) = @plan.folded(node)

          def variable_named(node)
            return node if node.is_a?(Symbol)

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # Whether +node+ can be put in a register without working anything out: a number written in the
          # program or a variable.
          def simple?(node) = !folded(node).nil? || !variable_named(node).nil? || node.is_a?(LabelAddress)

          # +node+, which is #simple?, into +register+.
          def emit_load_simple(node, register)
            known = folded(node)
            return emit_load_constant(known, register) if known
            return @asm.la(register, node.label) if node.is_a?(LabelAddress)

            emit_load_variable(variable_named(node), register)
          end

          # The left side worked out into v0 and the right side into v1, then the block: the right side
          # straight from where it is when that needs nothing worked out; when only the right side needs
          # working out, it first, moved to v1, and the left side then put straight in v0 (working a value
          # out changes no variable, so the left side reads the same either way); and otherwise the right
          # side worked out first, pushed, and pulled into v1 once the left side is in v0.
          def with_right_operand(left, right)
            if simple?(right)
              emit_value(left)
              emit_load_simple(right, :v1)
            elsif simple?(left)
              emit_value(right)
              @asm.move(:v1, :v0)
              emit_load_simple(left, :v0)
            else
              emit_value(right)
              emit_keep_temporary(:v0)
              emit_value(left)
              emit_restore_temporary(:v1)
            end
            yield
          end

          # What is left after dividing by a positive power of two, as Int32.mod has it: the sign of the
          # divisor, so it is the low bits alone (-1 % 16 is 15, and so is -1 & 15). True when done so.
          def emit_remainder_by_power_of_two(node)
            divisor = folded(node.rhs)
            return false unless divisor&.positive? && (divisor & (divisor - 1)).zero?

            emit_value(Build.binop(:&, node.lhs, Build.int(divisor - 1)))
            true
          end

          # `/` by a number written in the program, other than 1, 0 and -1, which the runtime's divide
          # answers as Int32.div does: a shift for a power of two and a multiply for any other
          # (IR::ConstantDivisor), and a negative divisor the same division with the answer negated. The
          # R3000's DIV is a wait of dozens of cycles and a call; this is a handful of instructions and one
          # MULT, whose wait is shorter. True when done so.
          def emit_divide_by_number(node)
            divisor = folded(node.rhs)
            return false unless divisor && divisor.abs > 1

            emit_value(node.lhs)
            emit_quotient_by(divisor.abs)
            @asm.subu(:v0, :zero, :v0) if divisor.negative?
            true
          end

          # `%` by a number written in the program, other than 1, 0 and -1, with Int32.mod's meaning: the
          # sign of the divisor. The quotient (#emit_quotient_by) times the size, taken off the numerator,
          # leaves what is left with the sign of the numerator; the size is added back to a negative one,
          # which puts it in 0...size, and for a negative divisor any but nought then moves down a size,
          # into -size...0. No branch: the sign bit and SLTU's nought-or-one make the masks. True when done.
          def emit_remainder_by_number(node)
            divisor = folded(node.rhs)
            return false unless divisor && divisor.abs > 1

            size = divisor.abs
            emit_value(node.lhs)
            emit_quotient_by(size)
            @asm.li(:t0, size)
            @asm.mult(:v0, :t0)
            @asm.mflo(:v0)
            @asm.subu(:v0, :t1, :v0)  # the numerator less quotient times size: the sign of the numerator
            @asm.sra(:t1, :v0, 31)
            @asm.and(:t1, :t1, :t0)
            @asm.addu(:v0, :v0, :t1)  # in 0...size
            return true unless divisor.negative?

            @asm.sltu(:t1, :zero, :v0)
            @asm.subu(:t1, :zero, :t1)
            @asm.and(:t1, :t1, :t0)
            @asm.subu(:v0, :v0, :t1)  # in -size...0
            true
          end

          # v0 divided by +size+ (2 or more), truncating toward nought, the numerator left in t1.
          #
          # A power of two is an arithmetic shift, which rounds toward minus infinity, so a negative
          # numerator is first lifted by one less than the size: its sign, spread over the word by SRA and
          # brought down to that many ones by SRL. Any other size is IR::ConstantDivisor#quotient's steps:
          # MULT leaves the 64-bit product in HI and LO, HI is the product divided by 2**32, the numerator
          # goes back in for a recipe that asks, a shift takes it the rest of the way, and the answer's
          # own sign bit added lifts a negative one toward nought.
          def emit_quotient_by(size)
            @asm.move(:t1, :v0)
            bits = ConstantDivisor.power_of_two_bits(size)
            if bits
              @asm.sra(:t0, :v0, 31)
              @asm.srl(:t0, :t0, 32 - bits)
              @asm.addu(:v0, :v0, :t0)
              @asm.sra(:v0, :v0, bits)
              return
            end

            recipe = ConstantDivisor.recipe_for(size)
            @asm.li(:t0, recipe.multiplier)
            @asm.mult(:v0, :t0)
            @asm.mfhi(:v0)
            @asm.addu(:v0, :v0, :t1) if recipe.add_numerator
            @asm.sra(:v0, :v0, recipe.shift) if recipe.shift.positive?
            @asm.srl(:t0, :v0, 31)
            @asm.addu(:v0, :v0, :t0)
          end

          # `<<` and `>>` by a number written in the program, in range: one shift. True when done so.
          def emit_shift_by_number(node)
            count = folded(node.rhs)
            return false unless count&.between?(0, 31)

            emit_value(node.lhs)
            node.op == :<< ? @asm.sll(:v0, :v0, count) : @asm.sra(:v0, :v0, count)
            true
          end

          # A runtime routine taking +args+ in Runtime::ARGUMENTS. Each that needs working out is worked out
          # in order and kept (#emit_keep_temporary), but the last, which goes straight to its register
          # since nothing is worked out after it; then the kept ones are taken into theirs, the last first;
          # then the ones that are only a number, a variable or a label's address are put in theirs.
          def runtime_call(name, args)
            registers = Runtime::ARGUMENTS
            worked = args.each_index.reject { |i| simple?(args[i]) }
            *pushed, last = worked
            pushed.each do |i|
              emit_value(args[i])
              emit_keep_temporary(:v0)
            end
            if last
              emit_value(args[last])
              @asm.move(registers.fetch(last), :v0)
            end
            pushed.reverse_each { |i| emit_restore_temporary(registers.fetch(i)) }
            args.each_with_index { |arg, i| emit_load_simple(arg, registers.fetch(i)) unless worked.include?(i) }
            call_routine(name)
          end
        end
      end
    end
  end
end
