# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        # One program, lowered straight to 68000 machine code: the Genesis's peer of the Super
        # Nintendo's, Color's and Advance's lowerings. It walks the IR with a table naming the method
        # for each kind of statement and each kind of value (the interpreter's own shape, Reference),
        # and emits the instructions through the assembler (M68000), calling the runtime
        # (Genesis::Runtime) for what is too long to write in place.
        #
        # How a number is worked out. Every value leaves its answer in D0, a data register that is
        # 32 bits wide, as a game's numbers are, so there is never a high half or a low one to
        # keep apart. A sum of two works the left-hand side out into D0 and takes the right-hand side
        # from where it already is — a number written in the program is part of the instruction, a
        # variable is read where it lives — so `x + 1` is two instructions and no call. A right-hand
        # side that has to be worked out first is worked out and kept in D2, or pushed on the stack,
        # while the left-hand side is worked out into D0 (#with_right_operand). A runtime routine taking several numbers has them in
        # D0, D1, D2... Nothing is kept in a register from one statement to the next, so a statement
        # never has to know what came before it.
        #
        # Where things live. The game's variables, and each routine's own numbers — a loop's count, a
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

          # Must come before Picture, whose emit_sprite_walk_read takes the place of the walk's own.
          include DrawOrderWalk
          include Paint
          include Picture
          include Collision
          include Saving
          include Sound
          include Division
          include Products
          include ControlFlow
          include ListPacking::Loops
          include SceneryWrites
          include MeasuredOnCopies
          include TileRuns
          include PoseRooms
          include ShownSort
          include BendSchedule
          include Bends

          # Every kind this lowering writes: its own, each by a method called by name in
          # #emit_statement and #value_of_kind, and each part's (Paint, Picture, Sound, Collision, and
          # the loops and tests every cartridge lowering shares, ControlFlow), which each part writes
          # in a case of its own. A declaration writes nothing where it is.
          # Read by test_genesis_kind_coverage.rb.
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp call call_one_of
            halt stop_full wait_vblank list_new list_push list_drop list_set list_fill list_copy list_sort list_pack
            timer_start timer_stop on_timer show_light_now rumble show_held_tiles show_picture_group screen
          ] + ControlFlow::STATEMENT_KINDS + Paint::STATEMENT_KINDS + Picture::STATEMENT_KINDS + Sound::STATEMENT_KINDS +
            Saving::STATEMENT_KINDS + TileRuns::STATEMENT_KINDS +
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
            when :repeat then stepped_walk?(node) ? emit_stepped_walk(node) : emit_control_flow_statement(node)
            when *ControlFlow::STATEMENT_KINDS then emit_control_flow_statement(node)
            when :call then emit_call(node)
            when :call_one_of then emit_call_one_of(node)
            when :halt then emit_halt(node)
            when :stop_full then emit_stop_full(node)
            when :wait_vblank then emit_wait_vblank(node)
            when :list_new then emit_list_new(node)
            when :list_push then emit_list_push(node)
            when :list_drop then emit_list_drop(node)
            when :list_set then emit_list_set(node)
            when :list_fill then emit_list_fill(node)
            when :list_copy then emit_list_copy(node)
            when :list_sort then emit_list_sort(node)
            when :list_pack then emit_list_pack(node)
            when :timer_start then emit_timer_start(node)
            when :timer_stop then emit_timer_stop(node)
            # a timer's handler runs as its timer ticks, not where it is written
            when :on_timer then emit_nothing(node)
            # no light can be made on a Genesis (its answers refuse one), and a game without one
            # works nothing out again
            when :show_light_now then emit_nothing(node)
            # a Genesis cartridge has no rumble motor, so nothing is felt (Console::Description#rumbles)
            when :rumble then emit_nothing(node)
            # video memory is written only between frames here, so a held background's changes
            # already show together
            when :show_held_tiles then emit_nothing(node)
            # every picture is in video memory whichever group is up (the interpreter's own check
            # is all that groups are for here)
            when :show_picture_group then emit_nothing(node)
            # a tiled screen is the one the console is set up for at power-on
            when :screen then emit_nothing(node)
            when *Paint::STATEMENT_KINDS then emit_paint_statement(node)
            when *Picture::STATEMENT_KINDS then emit_picture_statement(node)
            when *Sound::STATEMENT_KINDS then emit_sound_statement(node)
            when *Saving::STATEMENT_KINDS then emit_saving_statement(node)
            when *TileRuns::STATEMENT_KINDS then emit_tile_runs_statement(node)
            else emit_declaration_or_refuse(node)
            end
          end

          # A declaration is gathered before the program is written, so it writes nothing where it
          # is; any other kind with no writer is a mistake in this file.
          def emit_declaration_or_refuse(node)
            return emit_nothing(node) if Nodes.of_role(:declaration).include?(node.kind)

            raise LoweringError, "no writer here for #{node.kind.inspect}"
          end

          VALUE_KINDS = (%i[
            int var_ref binop neg bit_not absolute clamped shift_right held pressed pulled list_get list_len
            table_get timer_ticks chance mul_fix div_fix data_byte players_connected local_player
          ] + Collision::VALUE_KINDS + Saving::VALUE_KINDS).freeze

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
            when :pulled then value(Build.pulled_as_held(node))
            when :list_get then value_of_list_get(node)
            when :list_len then value_of_list_len(node)
            when :table_get then value_of_table_get(node)
            when :timer_ticks then value_of_timer_ticks(node)
            when :chance then value_of_chance(node)
            when :mul_fix then value_of_mul_fix(node)
            when :div_fix then value_of_div_fix(node)
            when :data_byte then value_of_data_byte(node)
            when :players_connected then value_of_players_connected(node)
            when :local_player then value_of_local_player(node)
            when *Collision::VALUE_KINDS then value_of_collision_kind(node)
            when *Saving::VALUE_KINDS then value_of_saving_kind(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # Every kind this lowering cannot make yet, by what it is part of. A kind leaves the list the
          # day the Genesis does it; test_genesis_kind_coverage.rb holds the list and the kind lists above
          # to every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({
                                                    "the status bar" => %i[place_bar],
                                                    "sprite tiles the game loads" => %i[load_sprite_tiles],
                                                    "layers see-through" => %i[see_through],
                                                    "save memory" => %i[save_erase save_sum save_load_list save_store_list]
                                                  })

          # How the runtime's list copy knows each way of keeping an entry (Runtime::Lists::KEPT), by
          # its bytes and its sign (LoweringPlan#table_keeping).
          TABLE_KEPT = Ractor.make_shareable({ [1, true] => :signed_byte, [1, false] => :byte, [2, true] => :signed_half,
                                               [2, false] => :half, [4, true] => :word })

          # The runtime's routines for a binop worked out by a call.
          CALLED_SUMS = Ractor.make_shareable({ :* => "rt_mul32", :/ => "rt_div32", :% => "rt_mod32",
                                                :<< => "rt_shl32", :>> => "rt_shr32" })
          IN_PLACE_OPS = %i[+ - & | ^].freeze
          COMPARISONS = %i[< <= > >= == !=].freeze

          # The condition under which a comparison does not hold, which is where a branch over what
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
          # tiles alone, :sprites for its sprite pictures' too. +scene_colors+ the same for its colours,
          # each scene's own written into the palettes as it takes over (Art), for a game whose colours
          # together do not fit. +streamed+ names the sprites kept to one pose in video memory at a time
          # (PoseRooms), for a game whose tiles do not fit even so. +remapped_lists+ draws a sprite drawn with
          # lists of colours from copies of its poses in each list's colours (Picture#remapped?), for a game
          # whose lists do not fit a palette each. +cache+ is what the build works out
          # from the program once for all its tries (BuildCache).
          def initialize(program, memory:, scene_tiles: false, scene_colors: false, streamed: [], remapped_lists: false,
                         cache: BuildCache.for(Genesis, program))
            @program = program
            @cache = cache
            @memory = memory
            @scene_tiles = scene_tiles
            @scene_colors = scene_colors
            @streamed = streamed
            @remapped_lists = remapped_lists
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
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @cell_tables = {} # the words a picked tile's cells hold (Picture#emit_set_picked_tile_of) -> their table's label
            @cell_blocks = {} # what a block of cells is written from (Picture#emit_set_tile_block_of) -> its label
            @slot_places = {} # where a pool's lists keep their slots, by list (#place_pools)
            @section_routines = {}
            @indexes_checked = {} # a loop's count -> the fewest items it is checked to be below (#index_checked_below?)
            @pictures = by_kind(:bitmap)
            prepare_paint
            prepare_picture
            prepare_collision
            prepare_sound
            @cuts = RoutineCuts.for(self, cache)
          end

          # The console this lowers for (BuildCache).
          CONSOLE = Console::GENESIS

          # How the program draws: :painted, :tiled (it names `screen :tiled`, or has a background or a
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
            program.walk.any? { |node| %i[fade tint color_list_holds background_colors].include?(node.kind) } ||
              Picture.scene_backdrops?(program)
          end

          # Whether the game holds numbers with a fraction, which is when the cartridge carries the
          # routines that work them out (Runtime::Int32.emit_fractions).
          def fractions? = @program.walk.any? { |node| %i[mul_fix div_fix].include?(node.kind) }

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            @plan.refuse_unbuildable!(not_lowered_yet: NOT_LOWERED_YET, not_made_yet: NotMadeYet, makes_poses_of_banks: true)
            refuse_unsupported_save_memory!
            refuse_unmade_picture!
            refuse_unmade_tile_runs!
            assign_background_layers unless painted?
            make_sprite_art
            (Reach.variables(@program) | loop_variables).each do |name|
              @variables[name] = @memory.reserve("the variable #{name.inspect}", 4)
            end
            @declared_lists.each_value do |node|
              width = LoweringPlan::SLOT_BYTES.fetch(node.width)
              capacity = @plan.most_list_capacity(node.name)
              place = @memory.reserve("the list #{node.name.inspect}", Runtime::Lists::HEADER + (capacity * width))
              @lists[node.name] = [place, capacity, width, node.name.to_s]
            end
            place_pools
            reserve_patches
            keep_tile_runs
            refuse_tiles_past_room_early!
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_scene_held_sets
            keep_timer_numbers
            keep_column_numbers
            keep_corner_notes((0...PLANES).to_a, bar: nil) # the Genesis build places no status bar yet
            keep_loop_running
            keep_order_tables
            routines = @called.flat_map do |name|
              @lowering_scene = @scenes.key?(name) ? name : nil
              with_call_numbers_recorded_for(name) do
                routines_fitting(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
              end
            end
            timers = timer_sections
            @lowering_scene = nil
            bend_routine = bend_sections
            main = routines_fitting(MAIN, @program.children, routine: "the game loop")
            [data_section, video_registers_section, *table_sections, *routines, *timers, *bend_routine, *main,
             *column_sections, *paint_sections, *art_sections, *tile_runs_section, *pose_rooms_sections, *collision_sections]
          end

          private

          # The assembler a run of statements is measured in (MeasuredOnCopies#bytes_of).
          def measuring_assembler = M68000.new("measuring", holds: ROUTINES)

          def by_kind(kind) = @program.walk.select { |node| node.kind == kind }.to_h { |node| [node.name, node] }

          def picture_named(name)
            @pictures.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
          end

          # The variables the game loops keep of their own, in the console's order
          # (IR::Frames::ConsoleLoop).
          def loop_variables = @plan.game_loops.flat_map { |node| console_loop(node).variables }

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

          # The planes' size, as the register holds it: a tiled screen's own, and for any other the 64 across
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
              value = Console::GenesisHardware::MODE3_HSCROLL_LINES if register == Console::GenesisHardware::REG_MODE3 && bends.any?
              value = Runtime::Strikes::STRIDE - 1 if register == Console::GenesisHardware::REG_HINT && Runtime::Strikes.wanted?(@program)
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
            @cell_tables.each do |words, label|
              asm.label(label)
              asm.data_words(words)
            end
            @cell_blocks.each do |(columns, rows, command, stride, source), label|
              asm.label(label)
              asm.data_words(columns, rows, command, stride)
              asm.data_longs(source)
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
            @indexes_checked = {} # a routine is called from anywhere
            @checks_kept_inside = nil
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
            name = DerivedNames.local_number_name(@routine, what, @locals.length + 1)
            @locals[name] = @memory.reserve("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            record_call_number(name, what)
            name
          end

          # The numbers each call of a routine keeps of its own (ControlFlow#call_numbers), put back
          # around the block's code, for every routine the frame boundary can call while a call of it is
          # waiting there (LoweringPlan#routines_reentered_at_frame_boundary): each moved onto the stack
          # before, and off it back to its place after, so the call that waits goes on from its own
          # loop's turn, as the interpreter's does, whatever the boundary's call left there. A game whose
          # boundary calls no such routine has no code here.
          #
          # A count a loop holds in a data register (#with_counter_held) needs nothing: such a loop has
          # no call and no wait in it, so it is never part way through at a frame boundary, which comes
          # only inside rt_wait_vblank; its count is in its place again by the time a routine waits.
          #
          # Around the timers, +kept+ is those and what a tick handler that waits keeps
          # (ControlFlow#numbers_kept_around_timers).
          def with_call_numbers_kept(kept = call_numbers)
            return yield if kept.empty?

            kept.each { |name| @asm.move(:l, at(place_of(name)), @asm.pre(M68000::SP)) }
            yield
            kept.reverse_each { |name| @asm.move(:l, @asm.post(M68000::SP), at(place_of(name))) }
          end

          # Where the variable +name+ (or a number of a routine's own) is kept, as an address.
          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # The operand that names that place: a distance from A5; or the data register a loop is
          # keeping it in while its body is written (#with_counter_held), or a bend's rows are keeping
          # it in while they read it (Bends#emit_bend_rows_held).
          def var(name) = @counters_held&.fetch(name, nil) || @reads_held&.fetch(name, nil) || at(place_of(name))

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
            unchanged: %i[@cuts @cache @keyed_sorts @shown_sorts @keys_set_by_sort]
          )

          # --- statements ---

          # Each statement made, with what it lets later ones know of the indexes checked
          # (#index_checked_below?): a statement that runs straight through keeps what is known and
          # adds its own checks, then forgets the variable it writes. Any other may jump about, run
          # its parts again, call a routine that writes anything or wait out the frame, so inside it
          # what was known holds until its first label (#place_label), and after it only what nothing
          # but an enclosing loop writes, a loop's count, is still known. A test's body runs only
          # after its test, so it starts knowing what was known before the test.
          def statement(node)
            if node.is_a?(RoutineCuts::PartCall)
              call_routine(node.label)
              return @indexes_checked = checks_only_loops_write
            end
            return emit_straight_line_statement(node) if STRAIGHT_LINE_KINDS.include?(node.kind)

            outside = @checks_kept_inside
            @checks_kept_inside = checks_only_loops_write
            @indexes_checked = @checks_kept_inside.dup unless node.kind == :if
            begin
              emit_statement(node)
            ensure
              @indexes_checked = @checks_kept_inside
              @checks_kept_inside = outside
            end
          end

          # The statements that run every part of themselves, once, in order, each writing at most
          # one variable as it ends (#variable_written).
          STRAIGHT_LINE_KINDS = %i[set add sub copy negate abs negate_abs clamp list_set].freeze

          def emit_straight_line_statement(node)
            @noting_checks = true
            emit_statement(node)
          ensure
            @noting_checks = false
            @indexes_checked.delete(variable_written(node))
          end

          # The variable a statement of STRAIGHT_LINE_KINDS writes, or nil for a list's slot.
          def variable_written(node)
            case node.kind
            when :copy then node.dest
            when :list_set then nil
            else node.var
            end
          end

          # What is known of the indexes checked that holds wherever the code goes: checks of a count
          # only its loop writes (#with_counter_held).
          def checks_only_loops_write
            @indexes_checked.select { |name, _| @counts_only_the_loop_writes&.include?(name) }
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
            return if emit_set_in_place(node)

            value(node.value)
            store(node.var)
          end

          # A number written in the program, straight into the variable +name+.
          def store_number(name, number)
            place = var(name)
            return @asm.moveq(number, place) if place.mode == :dn && number.between?(-128, 127)
            return @asm.clr(:l, place) if number.zero?

            @asm.move(:l, @asm.imm(number), place)
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`, in place: one instruction for a number written in the
          # program, and for anything else n worked out into D0 and added to x where it is, ADD.L
          # D0 to the variable. Worked out as `x + n` instead, x is read into D0 with n kept in D2
          # and the sum written back, two moves of a long to and from work RAM where the add to it
          # is one. n is worked out before x is read either way (#with_right_operand), so nothing
          # reads anything in another order.
          def emit_sum(name, op, operand)
            known = folded(operand)
            return emit_sum_of_number(name, op, known) if known

            other = variable_named(operand)
            other ? @asm.move(:l, var(other), @asm.d(0)) : value(operand)
            emit_long_sum(op, @asm.d(0), var(name))
          end

          # `x = x op y` for one of IN_PLACE_OPS with y worked out (#emit_sum), or nil where +node+
          # is not that. True when it was done so.
          def emit_set_in_place(node)
            sum = node.value
            return nil unless sum.is_a?(Node) && sum.kind == :binop && IN_PLACE_OPS.include?(sum.op)
            return nil unless variable_named(sum.lhs) == node.var && folded(sum.rhs).nil? && variable_named(sum.rhs).nil?

            value(sum.rhs)
            emit_long_sum(sum.op, @asm.d(0), var(node.var))
            true
          end

          # +destination+ +operator+= +source+, 32 bits, for one of IN_PLACE_OPS.
          def emit_long_sum(operator, source, destination)
            case operator
            when :+ then @asm.add(:l, source, destination)
            when :- then @asm.sub(:l, source, destination)
            when :& then @asm.and(:l, source, destination)
            when :| then @asm.or(:l, source, destination)
            when :^ then @asm.eor(:l, source, destination)
            else raise LoweringError, "#{operator.inspect} is not a sum written in place"
            end
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

          # --- what ControlFlow asks of a lowering, in the 68000's instructions ---

          def fresh_label(what) = fresh(what)
          # A label of a loop or a test can be jumped to from anywhere in it, so past one only what
          # holds all through the statement is known of the indexes checked (#statement).
          def place_label(label)
            @indexes_checked = (@checks_kept_inside || checks_only_loops_write).dup
            @asm.label(label)
          end
          def jump(label) = @asm.bra(label)
          def emit_value(operand) = value(operand)
          def emit_store(name) = store(name)
          def emit_store_zero(name) = store_number(name, 0)
          def loop_statements(node) = children_of(node).first
          def game_loops = @plan.game_loops
          def loop_form = @plan.loop_form

          # A loop's count kept in a data register (ControlFlow::OWN_WAYS). The 68000 adds one to a
          # register and compares it in a third of the time it takes on a place in work RAM, and a
          # body reading the loop's index, as most do to find a slot of a list, reads a register in
          # a quarter of the time. A console's own game keeps its count there for that reason.
          #
          # It is done only where nothing can overwrite the register or need the variable while the
          # loop runs: every statement of the body, however deep, is one this lowering writes in
          # place with D0, D1, D2 and A0 alone (#statement_keeps_counters?), so there is no call, of
          # the game's routines or the runtime's, and no wait, where a pass could end and the
          # variable be read. Any other loop counts in work RAM, as before. A loop inside one takes
          # the next register, three deep. The count goes back to its variable as the loop ends,
          # so what comes after reads what it always did.
          COUNTER_REGISTERS = [7, 6, 5].freeze

          def with_counter_held(node, counter, loaded: false)
            @counters_held ||= {}
            register = COUNTER_REGISTERS[@counters_held.size]
            return yield unless register && children_of(node).first.all? { |child| statement_keeps_counters?(child) } &&
                                (node.stop_when.nil? || value_keeps_counters?(node.stop_when))

            @asm.move(:l, var(counter), @asm.d(register)) if loaded
            @counters_held[counter] = @asm.d(register)
            @indexes_checked.delete(counter)
            (@counts_only_the_loop_writes ||= []) << counter if counter == node.index
            steps = loaded ? {} : held_steps(node, counter)
            unless steps.empty?
              @asm.movem_push(:l, *steps.values.map { |reg| :"d#{reg}" })
              steps.each_value { |reg| @asm.moveq(0, @asm.d(reg)) }
            end
            @steps_held = steps.empty? ? nil : [counter, steps]
            begin
              yield
            ensure
              @counters_held.delete(counter)
              @counts_only_the_loop_writes&.delete(counter)
              @steps_held = nil
            end
            @asm.movem_pop(:l, *steps.values.map { |reg| :"d#{reg}" }) unless steps.empty?
            @asm.move(:l, @asm.d(register), var(counter))
          end

          # The registers a held loop keeps its count times a number in (#held_steps).
          STEP_REGISTERS = [3, 4].freeze

          # The numbers a loop holding its count keeps stepped, each factor with its register
          # (STEP_REGISTERS), or none.
          #
          # A body that works a number out as the count times a number written in the program,
          # `k * 3 + 1`, multiplies every turn, where the console's own loops add: the number is
          # held in a data register that starts at nought and has the factor added as each turn ends
          # (#emit_increment), beside the count's own add, and each read of it is that register
          # (#held_product). A product by a power of two is one shift and is left as it is. Only
          # where the loop counts in its own variable from nought and holds no loop of its own,
          # whose count or walk could want the same registers; the registers are saved and restored
          # around the loop, as code around it may keep something of its own in them.
          def held_steps(node, counter)
            return {} unless counter == node.index && @steps_held.nil?

            body = children_of(node).first
            return {} if body.any? { |child| child.walk.any? { |inner| inner.kind == :repeat } }

            factors = body.flat_map { |child| child.walk.filter_map { |inner| stepped_factor(inner, counter) } }.uniq
            factors.first(STEP_REGISTERS.size).zip(STEP_REGISTERS).to_h
          end

          # The factor +node+ multiplies the loop's count +counter+ by, or nil: not nought, one or
          # a power of two, which are nothing or a shift.
          def stepped_factor(node, counter)
            return nil unless node.is_a?(Node) && node.kind == :binop && node.op == :* && variable_named(node.lhs) == counter

            factor = folded(node.rhs)
            return nil if factor.nil? || factor.zero? || (factor.positive? && (factor & (factor - 1)).zero?)

            factor
          end

          # The register a held loop keeps +node+ in (#held_steps), or nil.
          def held_product(node)
            return nil unless @steps_held && node.is_a?(Node) && node.kind == :binop && node.op == :*

            counter, steps = @steps_held
            return nil unless variable_named(node.lhs) == counter

            reg = steps[folded(node.rhs)]
            reg && @asm.d(reg)
          end

          # The loop's count one more, and each number it keeps stepped (#held_steps) on by its
          # factor.
          def emit_increment(name)
            if @steps_held && @steps_held.first == name
              @steps_held.last.each { |factor, reg| emit_long_sum_of_number(factor, @asm.d(reg)) }
            end
            emit_sum(name, :+, Build.int(1))
          end

          # +number+ added to +destination+: ADDQ or SUBQ for 1 to 8, and ADD of the long otherwise.
          def emit_long_sum_of_number(number, destination)
            if number.between?(1, 8) then @asm.addq(:l, number, destination)
            elsif number.between?(-8, -1) then @asm.subq(:l, -number, destination)
            else @asm.add(:l, @asm.imm(number), destination)
            end
          end

          # Is +node+ a statement written in place with D0, D1, D2 and A0 alone, everything it holds
          # too? A statement cut off into a routine of its own (RoutineCuts::PartCall) is a call.
          def statement_keeps_counters?(node)
            return false unless node.is_a?(Node)

            case node.kind
            when :set then value_keeps_counters?(node.value)
            when :add, :sub then value_keeps_counters?(node.operand)
            when :copy then value_keeps_counters?(node.src)
            when :negate, :abs, :negate_abs then true
            # A jump of the loop's own, or of a loop inside it, lands inside the loop's holding of
            # its count (ControlFlow#with_loop_targets), so the count is put back on the way out.
            when :break_repeat, :next_repeat then true
            when :clamp then value_keeps_counters?(node.min) && value_keeps_counters?(node.max)
            when :list_set
              !@lists_dropped_from_front.include?(node.name) && value_keeps_counters?(node.index) && value_keeps_counters?(node.value)
            when :if
              value_keeps_counters?(node.cond) && children_of(node).flatten.all? { |child| statement_keeps_counters?(child) }
            when :repeat
              value_keeps_counters?(node.count) && (node.stop_when.nil? || value_keeps_counters?(node.stop_when)) &&
                children_of(node).first.all? { |child| statement_keeps_counters?(child) }
            else false
            end
          end

          # Is +node+ a value worked out in place with D0, D1, D2 and A0 alone? (D2 only for the right
          # side of a sum, kept there while the left side is worked out: #with_right_operand.)
          def value_keeps_counters?(node)
            return true if node.is_a?(Symbol) || folded(node)
            return false unless node.is_a?(Node)

            case node.kind
            when :var_ref, :held, :pressed then true
            when :neg, :bit_not, :absolute then value_keeps_counters?(node.operand)
            when :clamped then [node.operand, node.min, node.max].all? { |part| value_keeps_counters?(part) }
            when :shift_right then node.bits.is_a?(Integer) && node.bits.between?(0, 31) && value_keeps_counters?(node.operand)
            when :list_get then !@lists_dropped_from_front.include?(node.name) && value_keeps_counters?(node.index)
            when :table_get then value_keeps_counters?(node.index)
            when :binop then sum_keeps_counters?(node)
            else false
            end
          end

          # A sum, a comparison, a shift by a number, or a product by a number or a comparison (Products):
          # the ones written in place. A product, a quotient or a shift the runtime works out is a call.
          def sum_keeps_counters?(node)
            both = value_keeps_counters?(node.lhs) && value_keeps_counters?(node.rhs)
            case node.op
            when *IN_PLACE_OPS, *COMPARISONS, :and, :or then both
            when :<<, :>> then both && folded(node.rhs)&.between?(0, 31) == true
            when :* then both && ([node.lhs, node.rhs].any? { |by| product_in_place?(folded(by)) } || product_by_comparison?(node))
            else false
            end
          end

          def emit_copy_variable(from, to)
            value(from)
            store(to)
          end

          def console_loop(node) = @plan.console_loop(node)

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)
            return call_routine(self.class.routine_label(node.target)) unless @held_walk

            # A routine called inside a held walk may use any register, so the walk's are kept
            # round the call.
            @asm.movem_push(:l, *WALK_REGISTERS)
            call_routine(self.class.routine_label(node.target))
            @asm.movem_pop(:l, *WALK_REGISTERS)
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
            return store_number(@scene, number) if painted? || (@scene_layers.zero? && !@scene_tiles && !@scene_colors)

            before = keep_local(:scene_before)
            statement(Build.set(before, Build.var_ref(@scene)))
            store_number(@scene, number)
            emit_scene_arrival(@scenes.key(number), before)
          end

          # A pass that halts ends as every pass does, with its sprites and scroll placed
          # (IR::Frames::ConsoleLoop#pass_end), as the interpreter ends it
          # (Reference#place_pass_end_before_halt), and nothing before any runs. A game that never waits has
          # its bends worked out as it stops, for the picture it stops on, as the interpreter works each
          # row out as it paints it.
          def emit_halt(_node)
            emit_bends(painting: true) if bends.any? && @program.walk.none? { |node| node.kind == :wait_vblank }
            loops_ending_passes.each_with_index do |ending, i|
              other = fresh("not_this_loop")
              jump_unless(Build.binop(:==, Build.var_ref(@loop_running), Build.int(i + 1)), other)
              console_loop(ending).pass_end.each { |child| statement(child) }
              @asm.label(other)
            end
            @asm.jmp(@asm.abs_l("rt_halt"))
          end

          # A full pool told to stop (Reference#exec_stop_full): no list, its capacity and its name's
          # number into FAULT for the reader to word as the interpreter does (CartridgeFaults::STOP_FULL).
          def emit_stop_full(node)
            @asm.move(:l, @asm.imm(0), runtime_at(Runtime::Frame::FAULT, Runtime::Frame::FAULT_LIST))
            @asm.move(:l, @asm.imm(node.capacity), runtime_at(Runtime::Frame::FAULT, Runtime::Frame::FAULT_FIRST))
            @asm.move(:l, @asm.imm(@plan.stop_full_number(node)),
                      runtime_at(Runtime::Frame::FAULT, Runtime::Frame::FAULT_SECOND))
            @asm.moveq(Runtime::Frame::STOP_FULL, @asm.d(0))
            @asm.jmp(@asm.abs_l("rt_fault"))
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them
          # (Reference#store_frame_counters): the frames shown by every frame the pass took, and what
          # the game catches up by held at the cap, both as the runtime counted them.
          #
          # The rows of each background bent row by row come first (Reference#work_out_bends): the wait's
          # blank sends the scroll this pass placed, and a row's bend goes out with it.
          def emit_wait_vblank(_node)
            emit_bends_at_wait
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
          # A draw order's list, kept in a table of its own (#emit_keyed_sort), starts it here too.
          def emit_list_new(node)
            keyed = @keyed_sorts&.fetch(node.name, nil)
            emit_order_tables_start(keyed) if keyed
            shown = @shown_sorts&.fetch(node.name, nil)
            if shown
              entries = keyed ? at(keyed.entries) : @asm.abs_l(@lists.fetch(node.name).first, Runtime::Lists::HEADER)
              emit_shown_start(shown, node.capacity, entries)
            end
            emit_capacity_into_header(node) if @plan.list_capacity_varies?(node.name)
            return list_call("rt_list_empty", node) unless node.full_of

            list_call("rt_list_at_capacity", node)
            return emit_pool_area_filled(node) if @pool_areas.key?(slot_place(node.name).area)

            list_call("rt_list_fill", node, Build.int(0), Build.int(node.capacity), Build.int(node.full_of))
          end

          # A list declared with several capacities (LoweringPlan#list_capacities) takes this
          # declaration's into its header, where the runtime reads it: what rt_list_at_capacity makes
          # the length, and what a push is held to. The start wrote the most of them there, which its
          # place has room for.
          def emit_capacity_into_header(node)
            @asm.move(:w, @asm.imm(node.capacity), @asm.abs_l(@lists.fetch(node.name).first, Runtime::Lists::CAPACITY))
          end

          # A pool's list kept in an area of the pool's block made full of its number, a slot at a time
          # at the pool's stride, the number kept multiplied where the slot keeps it so (a link, whose
          # NONE stays NONE).
          def emit_pool_area_filled(node)
            slot = slot_place(node.name)
            number = node.full_of.negative? ? node.full_of : node.full_of * slot.scale
            again = fresh("pool_fill")
            @asm.move(:l, @asm.imm(number), @asm.d(0))
            @asm.lea(at(area_place(slot), Runtime::Lists::HEADER + slot.offset), @asm.a(0))
            @asm.move(:w, @asm.imm(node.capacity - 1), @asm.d(1))
            @asm.label(again)
            @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot.width), @asm.d(0), @asm.ind(0))
            @asm.lea(@asm.disp(0, slot.stride), @asm.a(0))
            @asm.dbra(@asm.d(1), again)
          end
          def emit_list_push(node) = list_call("rt_list_push", node, node.value)
          def emit_list_drop(node) = list_call("rt_list_drop", node, Build.int(node.from == :front ? 1 : 0))
          def emit_list_fill(node) = list_call("rt_list_fill", node, node.from, node.count, node.value)

          # A list that always holds its capacity, read or written at a number written in the program
          # below that capacity: the slot is at an address known here, and the index can never be
          # outside the list, so the item is one move to or from that address, where the runtime's
          # routine takes the list's place handed over, a call, the index checked and scaled, and the
          # return. A draw order sets the number of each of its things this way every pass.
          def emit_list_set(node)
            return if key_set_by_sort?(node)

            slot = fixed_slot(node)
            if slot
              value(node.value)
              emit_slot_value_scaled(node)
              return @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot.last), @asm.d(0), at(slot.first))
            end
            return list_call("rt_list_set", node, node.index, node.value) if @lists_dropped_from_front.include?(node.name)

            held = held_field(node)
            return if held && emit_held_field_stepped(node, held)

            if held
              value(node.value)
              emit_slot_value_scaled(node)
              return @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot_bytes(node)), @asm.d(0), held)
            end

            emit_value_and_index(node.value, node.index)
            emit_slot_value_scaled(node)
            emit_slot_address(node, 1, fault: "rt_list_index_fault_of_d1")
            @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot_bytes(node)), @asm.d(0), slot_operand(node, 1))
          end

          def value_of_list_get(node)
            slot = fixed_slot(node)
            if slot
              address, bytes = slot
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(bytes), at(address), @asm.d(0))
              emit_slot_widening(bytes)
              return emit_slot_value_unscaled(node)
            end
            return list_call("rt_list_get", node, node.index) if @lists_dropped_from_front.include?(node.name)

            held = held_field(node)
            if held
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot_bytes(node)), held, @asm.d(0))
            else
              value(node.index)
              emit_slot_address(node, 0, fault: "rt_list_index_fault_of_d0")
              @asm.move(Runtime::Lists::SLOT_SIZES.fetch(slot_bytes(node)), slot_operand(node, 0), @asm.d(0))
            end
            emit_slot_widening(slot_bytes(node))
            emit_slot_value_unscaled(node)
          end

          # A field of the held thing moved on by a number written in the program, `t.x += 2`: one
          # instruction on the field where it is, ADDQ or SUBQ for 1 to 8 and ADDI or SUBI past that,
          # where reading it out, adding and writing it back is three. Each keeps the field's own
          # width, which is what the slot keeps of the sum the interpreter works out in 32 bits. True
          # where it was made so.
          def emit_held_field_stepped(node, held)
            value = node.value
            return false unless value.is_a?(Node) && value.kind == :binop && %i[+ -].include?(value.op)

            read = value.lhs
            by = folded(value.rhs)
            return false unless by && read.is_a?(Node) && read.kind == :list_get && read.name == node.name &&
                                read.index.is_a?(Node) && read.index.kind == :var_ref && read.index.name == node.index.name &&
                                slot_place(node.name).scale == 1

            by = -by if value.op == :-
            size = { 1 => :b, 2 => :w, 4 => :l }.fetch(slot_bytes(node))
            if by.between?(1, 8)
              @asm.addq(size, by, held)
            elsif by.between?(-8, -1)
              @asm.subq(size, -by, held)
            else
              @asm.add(size, @asm.imm(by), held)
            end
            true
          end

          # A link kept as the slot times the stride (PoolLayout.strided_place), two bytes with NONE
          # as $FFFF. Read and widened by its sign, NONE is -1 and any other the slot times the stride,
          # which an arithmetic shift right brings back to the slot and leaves -1 as it is.
          def emit_slot_value_unscaled(node)
            slot = slot_place(node.name)
            @asm.asr(:l, slot.scale.bit_length - 1, @asm.d(0)) if slot.scale > 1
          end

          # D0, a slot or NONE about to be written to a link kept multiplied, made the slot times the
          # stride; NONE is kept as it is.
          def emit_slot_value_scaled(node)
            slot = slot_place(node.name)
            return if slot.scale == 1

            kept = fresh("link_none")
            @asm.tst(:l, @asm.d(0))
            @asm.branch_near(:mi, kept)
            @asm.lsl(:l, slot.scale.bit_length - 1, @asm.d(0))
            @asm.label(kept)
          end

          # A list whose first item is always in its first slot, read or written where the game does
          # Every list is one unless the game takes items from its front (#lists_dropped_from_front),
          # and then the item an index names is in the slot of that number: A0 is pointed at the
          # list, the index is scaled to the slot's size, and one move reads or writes the slot
          # through the two. A call of a runtime routine for the same spends more on handing over
          # the list's place and the index, the call and the return than on the slot.
          #
          # The index is checked first, as the interpreter checks it (an index outside the list
          # stops the game): against the list's capacity as a number, for a list that always holds
          # that many, or against the length its header keeps. One compare catches an index below
          # nought too, since as a number that cannot be negative it is past any length. No check is
          # written where the index is a loop's variable known to stay below the capacity of a list
          # that is always full (ControlFlow#index_below).
          #
          # D(+index+) holds the index and is left holding the slot's distance; D(index + 1) is
          # worked with.
          def emit_slot_address(node, index, fault:)
            place = area_place(slot_place(node.name))
            # A list declared with several capacities is as long as the declaration run last made it,
            # so its length is read where it is kept.
            full = always_full_lists[node.name] unless @plan.list_capacity_varies?(node.name)
            @asm.lea(at(place), @asm.a(0))
            unless full && (index_inside?(node.index, full) || index_checked_below?(node.index, full))
              emit_list_length(full, index + 1)
              @asm.cmp(:l, @asm.d(index + 1), @asm.d(index))
              @asm.branch_over(:cs, LIST_FAULT_JUMP_BYTES)
              @asm.jmp(@asm.abs_l(fault))
              note_index_checked(node.index, full) if full
            end
            emit_slot_scaling(node, index)
          end

          # An index checked once. A variable nothing writes between two reads or writes of lists
          # that always hold their capacity is the same at both, so once the first has checked it,
          # the second needs no check if its list is at least as long: the first check stops the
          # game, as the interpreter stops it, before anything after it runs. A walk over four lists
          # at one index checks it once a turn, not at each of eight slots.
          #
          # What is known runs from one statement to the next only while each runs straight through
          # (#statement): a variable a statement writes is forgotten, and so is every one at a call,
          # a wait, a test's other side or a loop's next turn, except a loop's count held in a
          # register, which only the loop writes (#with_counter_held) and so stays the same through
          # a turn of its body.
          #
          # Is +index+ a variable already checked against +count+ items or fewer?
          def index_checked_below?(index, count)
            name = variable_named(index)
            below = name && @indexes_checked.fetch(name, nil)
            !below.nil? && below <= count
          end

          # +index+ checked just now against the +count+ items of a list that always holds them, in a
          # statement that runs straight through.
          def note_index_checked(index, count)
            name = variable_named(index)
            return unless name && @noting_checks

            @indexes_checked[name] = [@indexes_checked.fetch(name, count), count].min
          end

          # JMP to a whole address: the instruction's word and the address's two.
          LIST_FAULT_JUMP_BYTES = 6

          # D(+into+) = how many items the list A0 points at holds: +full+ where it always holds
          # that many, or else what its header keeps.
          def emit_list_length(full, into)
            return @asm.moveq(full, @asm.d(into)) if full&.between?(0, 127)
            return @asm.move(:l, @asm.imm(full), @asm.d(into)) if full

            @asm.moveq(0, @asm.d(into))
            @asm.move(:w, @asm.disp(0, Runtime::Lists::LENGTH), @asm.d(into))
          end

          # Is +index+ known, while building, to be a place in a list of +count+ items: a loop's
          # variable, a mask or a remainder that stays below a count no bigger than that
          # (ControlFlow#index_known_below)?
          def index_inside?(index, count)
            below = index_known_below(index)
            !below.nil? && below <= count
          end

          # The index in D(+index+) made the slot's distance in bytes. A list whose slots end within
          # 32K is scaled as a word, which is quicker: the index is known to be inside it by now.
          def emit_slot_scaling(node, index)
            size = slots_within_word?(node) ? :w : :l
            (slot_place(node.name).stride.bit_length - 1).times { @asm.add(size, @asm.d(index), @asm.d(index)) }
          end

          # The slot of the list A0 points at that the distance in D(+index+) names.
          def slot_operand(node, index)
            @asm.idx(0, Runtime::Lists::HEADER + slot_place(node.name).offset, index, slots_within_word?(node) ? :w : :l)
          end

          # How many bytes the value in a slot of +node+'s list is.
          def slot_bytes(node) = slot_place(node.name).width

          def slots_within_word?(node)
            _place, capacity, = @lists.fetch(node.name)
            slot = slot_place(node.name)
            slot.offset + (capacity * slot.stride) <= 0x7FFF
          end

          # D0, just read from a slot of +bytes+ bytes, widened by its sign.
          def emit_slot_widening(bytes)
            @asm.ext(:w, @asm.d(0)) if bytes == 1
            @asm.ext(:l, @asm.d(0)) if bytes < 4
          end

          # +value+ worked out into D0 and +index+ into D1, the index first where both need working
          # out, as a runtime routine's numbers are (#runtime_call).
          def emit_value_and_index(value_node, index_node)
            index = operand_of(index_node)
            if index
              value(value_node)
              return emit_operand_load(index, 1)
            end

            if operand_of(value_node)
              value(index_node)
              @asm.move(:l, @asm.d(0), @asm.d(1))
              return value(value_node)
            end

            push_value(index_node)
            value(value_node)
            @asm.move(:l, @asm.post(M68000::SP), @asm.d(1))
          end

          # A number or a variable (#operand_of) into D(+register+).
          def emit_operand_load(source, register)
            if source.mode == :imm && source.value.is_a?(Integer) && source.value.between?(-128, 127)
              @asm.moveq(source.value, @asm.d(register))
            else
              @asm.move(:l, source, @asm.d(register))
            end
          end

          # [the address of the slot, its bytes] that +node+'s index names, when the index is a number
          # written in the program and the list always holds its capacity, which the number is below;
          # or nil.
          def fixed_slot(node)
            capacity = always_full_lists[node.name]
            index = capacity && folded(node.index)
            return unless index&.between?(0, capacity - 1)

            slot = slot_place(node.name)
            [area_place(slot) + Runtime::Lists::HEADER + slot.at(index), slot.width]
          end

          # --- pools (Backends::PoolLayout) ---
          #
          # A pool is kept in the layout its placement gives: where slot s of each of its lists is, in
          # bytes from the start of the list's area (PoolLayout::SlotPlace), how wide its value is, and
          # the number it is kept multiplied by. Every read and write of a slot below asks #slot_place
          # for that, a pool's list and any other alike, and the headless run reads a pool's lists back
          # through the same (Places#slot_places). Kept as :lists, each slot list is an area of its
          # own, which is the list with its header, slot s at s times its width.
          #
          # Kept at one stride (:tables, :records), the pool's areas are reserved here one after
          # another in one block, so one address register on a thing's slot in the first area reaches
          # every field of it at a distance written in the instruction (#emit_stepped_walk); each
          # list keeps its header, and so its length, where the list itself is.
          def place_pools
            @slot_places = {}
            @pool_areas = {}
            @pool_blocks = {}
            console = @program.described_console
            (@program.pools || []).each do |shape|
              layout = PoolLayout.chosen(shape, console, PoolLayout.steps_on(@program, shape))
              placement = layout.place(shape)
              if placement.layout == :lists
                refuse_unmade_pool_placement!(shape, placement)
              else
                reserve_pool_areas(shape, placement)
              end
              @slot_places.merge!(placement.slots)
            end
          end

          # The areas of +placement+, a layout at one stride, reserved in one block for the pool +shape+.
          def reserve_pool_areas(shape, placement)
            even = ->(bytes) { (bytes + 1) & ~1 }
            block = @memory.reserve("the pool #{shape.name.inspect}", placement.areas.values.sum(&even))
            @pool_blocks[shape.name] = block
            placement.areas.reduce(block) do |address, (area, bytes)|
              @pool_areas[area] = address
              address + even.call(bytes)
            end
          end

          # A walk of a pool stepped as the console's own games step one. The tree's walk keeps the
          # thing it goes to next and the last it visits in variables, tests the next against NONE,
          # copies it into the thing it is on, compares that with the last, reads the link out of a
          # list at an index scaled each time, and counts its turns in a variable; and every field the
          # body reads or writes finds its list and scales the slot again. The 68000's way to reach
          # the fields of one thing is an address register on it and each field at a distance written
          # in the instruction, the address register indirect with displacement mode, d16(An): a read
          # of a word that way is twelve cycles, where finding the list, scaling the slot and reading
          # through an index takes several instructions (Motorola's M68000 Programmer's Reference
          # Manual for the mode; the MC68000 user's manual for the cycle counts).
          #
          # Here, for a pool kept at one stride: A3 holds the pool's block and D3 the thing's distance
          # into it, the slot times the stride, which is what the links keep; A4 is the thing's place
          # each turn, `lea 0(a3,d3.w),a4`, and every field of it in the body is d16(A4)
          # (#held_field); the next thing's distance is its link read at A4, and the walk ends on a
          # link of NONE, negative, where the chain cannot change during it
          # (LoweringPlan#chain_changed_during_walks?), else at the last thing as the tree does. D4
          # counts the turns as the repeat's index (#var). The walk's variables end as the tree
          # leaves them: the thing it was on, the next (NONE), and the index, one below the count
          # where the walk took every turn (Reference#exec_repeat).
          #
          # Only where nothing in the body can touch those registers: every statement of it is one
          # written in place with D0, D1, D2 and A0 (#statement_keeps_counters?), so no call and no
          # wait, and nothing in it writes the walk's own variables. One walk at a time is held.
          WALK_OFFSET = 3
          WALK_TURNS = 4
          WALK_BLOCK = 3
          WALK_THING = 4

          def stepped_walk?(node)
            walk = node.pool_walk
            return false unless walk && node.index && walk.step_statements == 2 && pool_block(walk.pool) && @held_walk.nil?
            return false unless children_of(node).first.equal?(node.children) || children_of(node).first == node.children

            capacity = folded(node.count)
            body = @plan.walk_body(node)
            nodes = body.flat_map { |child| child.walk.to_a }
            !capacity.nil? && capacity.between?(1, 0x7FFF) && body.all? { |child| statement_keeps_walk?(child) } &&
              nodes.none? { |each| [walk.at, walk.ahead, walk.last].any? { |name| names_variable?(each, name) } }
          end

          # Whether +node+ leaves a held walk's registers alone, or can be made to: one written in place
          # (#statement_keeps_counters?), a call of a routine that never waits, which is made with the
          # walk's registers kept on the stack around it (#emit_call), or a test of those.
          def statement_keeps_walk?(node)
            case node.kind
            when :call then @funcs.key?(node.target) && !@plan.waits?(node.target)
            when :if
              value_keeps_counters?(node.cond) && children_of(node).flatten.all? { |child| statement_keeps_walk?(child) }
            else statement_keeps_counters?(node)
            end
          end

          # The registers a held walk keeps (#emit_stepped_walk), as MOVEM names them.
          WALK_REGISTERS = %i[d3 d4 a3 a4].freeze

          # Whether +node+, other than by reading it, names the variable +name+ in what it holds.
          def names_variable?(node, name) = node.kind != :var_ref && node.attrs.values.flatten.any?(name)

          def emit_stepped_walk(node)
            walk = node.pool_walk
            links = slot_place(walk.links)
            shifts = links.stride.bit_length - 1
            body = @plan.walk_body(node)
            stops_at_last = @plan.chain_changed_during_walks?(walk.pool)
            reads_at = body.flat_map { |child| child.walk.to_a }.any? { |each| reads_current_beyond_fields?(each, walk) }
            top = fresh("walk")
            done = fresh("walk_done")
            offset = @asm.d(WALK_OFFSET)
            turns = @asm.d(WALK_TURNS)
            last = keep_local(:walk_last_distance) if stops_at_last
            @asm.moveq(0, turns)
            if stops_at_last
              @asm.move(:l, var(walk.last), @asm.d(0))
              @asm.lsl(:w, shifts, @asm.d(0)) if shifts.positive?
              @asm.move(:w, @asm.d(0), var(last))
            end
            @asm.lea(at(pool_block(walk.pool)), @asm.a(WALK_BLOCK))
            @asm.move(:l, var(walk.ahead), offset)
            @asm.branch(:mi, done)
            @asm.lsl(:w, shifts, offset) if shifts.positive?
            place_label(top)
            @asm.lea(@asm.idx(WALK_BLOCK, 0, WALK_OFFSET, :w), @asm.a(WALK_THING))
            if reads_at
              @asm.move(:w, offset, @asm.d(0))
              @asm.ext(:l, @asm.d(0))
              @asm.asr(:l, shifts, @asm.d(0)) if shifts.positive?
              @asm.move(:l, @asm.d(0), var(walk.at))
            end
            @held_walk = [walk, node.index]
            (@counters_held ||= {})[node.index] = turns
            begin
              body.each { |child| statement(child) }
            ensure
              @held_walk = nil
              @counters_held.delete(node.index)
            end
            @asm.addq(:l, 1, turns)
            if stops_at_last
              @asm.cmp(:w, var(last), offset)
              @asm.branch(:eq, done)
            end
            @asm.move(:w, @asm.disp(WALK_THING, field_distance(links, walk.pool)), offset)
            @asm.branch(:pl, top)
            place_label(done)
            emit_walk_ends(node, walk, reads_at)
          end

          # The walk's variables as the tree leaves them (#emit_stepped_walk): the thing it was on,
          # which is the last where it took a turn, written here where the body did not have it
          # written each turn; the next, NONE; and the index from the turns, one below the count
          # where the walk took every one.
          def emit_walk_ends(node, walk, reads_at)
            turns = @asm.d(WALK_TURNS)
            untouched = fresh("walk_untouched")
            counted = fresh("walk_counted")
            unless reads_at
              @asm.tst(:l, turns)
              @asm.branch(:eq, untouched)
              @asm.move(:l, var(walk.last), var(walk.at))
              @asm.label(untouched)
            end
            store_number(walk.ahead, DSL::Pool::NONE)
            @asm.cmp(:l, @asm.imm(folded(node.count)), turns)
            @asm.branch(:ne, counted)
            @asm.subq(:l, 1, turns)
            @asm.label(counted)
            @asm.move(:l, turns, var(node.index))
          end

          # Whether +node+ reads the walk's current thing other than as the index of a field the held
          # register reaches (#held_field).
          def reads_current_beyond_fields?(node, walk)
            node.attrs.values.flatten.any? do |operand|
              next false unless operand.is_a?(Node) && operand.kind == :var_ref && operand.name == walk.at

              !(%i[list_get list_set].include?(node.kind) && node.index.equal?(operand) && pool_field?(node.name, walk.pool))
            end
          end

          # Whether +list+ is one of +pool+'s lists kept in its block.
          def pool_field?(list, pool)
            slot = @slot_places[list]
            !slot.nil? && @pool_areas.key?(slot.area) && DSL::Pool.owner_of_list(list).to_s == pool.to_s
          end

          # The slot of +node+'s list at the thing a walk holds in A4, as an operand, where +node+ reads
          # or writes one of the held pool's fields at the walk's current thing; else nil.
          def held_field(node)
            walk, = @held_walk
            return unless walk && node.index.is_a?(Node) && node.index.kind == :var_ref && node.index.name == walk.at
            return unless pool_field?(node.name, walk.pool)

            @asm.disp(WALK_THING, field_distance(slot_place(node.name), walk.pool))
          end

          # The address of the first of +pool+'s areas, which every field of a thing is reached from
          # at a distance (#field_distance), or nil for a pool kept as lists.
          def pool_block(pool) = @pool_blocks[pool.to_sym]

          # How far +slot+, a SlotPlace of a pool kept at one stride, is from a thing's slot in the
          # pool's first area.
          def field_distance(slot, pool) = @pool_areas.fetch(slot.area) + slot.offset - pool_block(pool)

          # Where a list's slots are: a pool's list as its layout placed it, any other a slot of its
          # width after another.
          def slot_place(name)
            @slot_places.fetch(name) do
              _place, _capacity, bytes = @lists.fetch(name) { raise LoweringError, "the list #{name.inspect} is used and never declared" }
              PoolLayout::SlotPlace.new(area: name, offset: 0, stride: bytes, width: bytes, scale: 1)
            end
          end

          # Where the area +slot+ is in, as a list's place, its header first: a list's own place, or
          # for an area of a pool's block, as far before the area as a header is long.
          def area_place(slot)
            return @pool_areas.fetch(slot.area) - Runtime::Lists::HEADER if @pool_areas.key?(slot.area)

            @lists.fetch(slot.area).first
          end

          # The slots' places as the headless run reads them, by list, each counted from the end of
          # its list's own header (CartridgeHeadlessRun#slot_place_of).
          public def slot_places
            @slot_places.select { |list, _slot| @lists.key?(list) }.to_h do |list, slot|
              moved = area_place(slot) - @lists.fetch(list).first
              [list, moved.zero? ? slot : slot.with(offset: slot.offset + moved)]
            end
          end

          # A placement this lowering cannot keep yet: an area that is not one list of the tree, a
          # value kept multiplied, or slots not one after another. Today's lists are none of those.
          def refuse_unmade_pool_placement!(shape, placement)
            placement.slots.each do |list, slot|
              next if slot.area == list && @lists.key?(list) && slot.scale == 1 && slot.offset.zero? &&
                      slot.stride == slot.width && slot.width == @lists.fetch(list)[2]

              raise NotMadeYet.new("Pool :#{shape.name} is kept as #{placement.layout}. The Genesis build keeps a pool " \
                                   "only as lists for now. To fix this, give the pool `layout: :lists`, or no layout.",
                                   part: "a pool's layout")
            end
          end

          # The lists made full of one number and never made longer or shorter, so each holds its
          # capacity for good, by name, with that capacity (the least, if made twice). Every way a
          # list's length changes is a list_push, a list_drop, a list_copy, or a list_new that makes it
          # empty; a list_fill or a list_sort leaves it as long as it was. Nothing taken from the
          # front, so the first item stays in the first slot. Only one made before anything can read
          # or write it (LoweringPlan#lists_made_before_use): until it is made it holds nothing, and a
          # read there stops the game.
          def always_full_lists
            @always_full_lists ||= begin
              resized = @program.walk.filter_map do |node|
                node.name if %i[list_push list_drop list_copy].include?(node.kind) || (node.kind == :list_new && !node.full_of)
              end
              first = @plan.lists_made_before_use
              made = @program.walk.select do |node|
                node.kind == :list_new && node.full_of && !resized.include?(node.name) && first.include?(node.name)
              end
              made.group_by(&:name).transform_values { |nodes| nodes.map(&:capacity).min }
            end
          end
          def value_of_list_len(node) = list_call("rt_list_length", node)

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

          # A list put in order (Reference#exec_list_sort), written here in place: an insertion sort,
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
          #
          # A sort handed +shown+ asks each place first, and starts past the entries not showing
          # (ShownSort).
          def emit_list_sort(node)
            return node.children.each { |child| statement(child) } if node.by.nil? # the items alone: the insertion sort that means it

            keyed = @keyed_sorts&.fetch(node.name, nil)
            shown = @shown_sorts&.fetch(node.name, nil)
            emit_shown_sorted_first(node, shown, keyed) if shown
            return emit_keyed_sort(keyed, shown) if keyed

            order = @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is sorted and never declared" }
            keys = @lists.fetch(node.by) { raise LoweringError, "the list #{node.by.inspect} is sorted by and never declared" }
            stays = node.descending ? :ge : :le # the number before is not beyond this one's: it stays
            done = fresh("sorted")
            @asm.moveq(0, @asm.d(7))
            @asm.move(:w, @asm.abs_l(order.first, Runtime::Lists::LENGTH), @asm.d(7))
            @asm.sub(:w, at(shown.hidden), @asm.d(7)) if shown
            @asm.lea(@asm.abs_l(keys.first, Runtime::Lists::HEADER), @asm.a(1))
            if @lists_dropped_from_front.include?(node.name)
              emit_ring_sort(order, keys, stays, done)
            else
              emit_pointer_sort(order, keys, stays, done, shown)
            end
            @asm.label(done)
          end

          # Each place of a sort handed +shown+ asked whether it shows, and the order moved round on a
          # pass where one came or went (ShownSort).
          def emit_shown_sorted_first(node, shown, keyed)
            unchanged = fresh("sort_none_came_or_went")
            emit_shown_marked(node, shown)
            @asm.tst(:b, at(shown.changed))
            @asm.branch(:eq, unchanged)
            if keyed
              emit_shown_partition(shown, at(keyed.entries), keyed.count, :w, 2)
            else
              order = @lists.fetch(node.name)
              emit_shown_partition(shown, @asm.abs_l(order.first, Runtime::Lists::HEADER), order[1],
                                   Runtime::Lists::SLOT_SIZES.fetch(order[2]), 0)
            end
            @asm.label(unchanged)
          end

          # The sort over a list whose first item is in its first slot. D7 counts the items left to
          # place, from the second; D3 is the one being placed and D4 its number; D5 the one before
          # the gap and D6 its number. A sort handed +shown+ starts at the first entry showing, which
          # nothing goes back past.
          def emit_pointer_sort(order, keys, stays, done, shown = nil)
            size = Runtime::Lists::SLOT_SIZES.fetch(bytes = order[2])
            item = fresh("sort_item")
            back = fresh("sort_back")
            stay = fresh("sort_stay")
            place = fresh("sort_place")
            @asm.subq(:l, 1, @asm.d(7))
            @asm.branch(:le, done)
            if shown
              emit_first_shown_entry(shown, @asm.abs_l(order.first, Runtime::Lists::HEADER), bytes)
            else
              @asm.lea(@asm.abs_l(order.first, Runtime::Lists::HEADER), @asm.a(0))
            end
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

          # A draw order's sort, kept in a table of its own (LoweringPlan#sorts_kept_apart): the order
          # list is the framework's, nothing else reads it and nothing compares it with the
          # interpreter's, so the order is kept instead as a table of words in reach of A5, one a place,
          # each its item already four times over — how far into the numbers its number is, and into
          # the table of the sprites' placings (Picture#emit_ordered_run) its placing. The order list
          # keeps the order the game started in. The numbers stay in their list, as every backend
          # keeps them.
          #
          # The sort above takes each item out, reads its number and walks back from it with two
          # pointers, about fourteen instructions a thing on a frame where nobody passed anybody. Here
          # every place is written out once as the cartridge is built: its item read where it lies, its
          # number read through it, one compare with the number before, which stays in D2 for the next.
          # Five instructions a thing. An item that does move goes to one routine that moves it back
          # as the sort above does.
          KeyedSort = Data.define(:order, :keys, :count, :entries, :descending)

          # Which sorts are kept in a table of their own, and where each table is. The table is only
          # a faster way to the same order, so a game whose work RAM has no room left for one keeps
          # the sort above instead of stopping with memory full, as the SNES does.
          def keep_order_tables
            @keyed_sorts = {}
            @plan.sorts_kept_apart.each do |name, node|
              count = @plan.most_list_capacity(node.name)
              entries = begin
                @memory.reserve("the items of the order #{node.name.inspect}", count * 2)
              rescue Memory::Full
                next
              end
              @keyed_sorts[name] = KeyedSort.new(order: node.name, keys: node.by, count: count,
                                                 descending: node.descending, entries: entries)
            end
            keep_shown_sorts(@keyed_sorts)
          end

          # The table as the order starts: item +n+ in place +n+.
          def emit_order_tables_start(keyed)
            keyed.count.times { |place| @asm.move(:w, @asm.imm(place * 4), at(keyed.entries, place * 2)) }
          end

          # Each place after the first compared with the one before it. D1 is this place's number and
          # D2 the one before's; D0 this place's item. A1 is the first of the numbers' slots.
          #
          # A sort handed +shown+ (ShownSort) starts at the first entry showing, through a table of
          # where each place's compare starts, with the number of that entry in D2.
          def emit_keyed_sort(keyed, shown = nil)
            mover = fresh("sort_move")
            done = fresh("sorted")
            stays = keyed.descending ? :le : :ge # this number is not beyond the one before: it stays
            starts = (1...keyed.count).map { fresh("sort_place") }
            @asm.lea(@asm.abs_l(@lists.fetch(keyed.keys).first, Runtime::Lists::HEADER), @asm.a(1))
            if shown
              emit_keyed_start_past_hidden(keyed, shown, starts, done)
            else
              @asm.move(:w, at(keyed.entries), @asm.d(0))
              @asm.move(:l, @asm.idx(1, 0, 0, :w), @asm.d(2))
            end
            (1...keyed.count).each do |place|
              stay = fresh("sort_stays")
              past = fresh("sort_past")
              @asm.label(starts[place - 1])
              @asm.move(:w, at(keyed.entries, place * 2), @asm.d(0))
              @asm.move(:l, @asm.idx(1, 0, 0, :w), @asm.d(1))
              @asm.cmp(:l, @asm.d(2), @asm.d(1))
              @asm.branch(stays, stay)
              @asm.move(:w, @asm.imm(place * 2), @asm.d(3))
              @asm.bsr(mover)
              @asm.bra(past)
              @asm.label(stay)
              @asm.move(:l, @asm.d(1), @asm.d(2))
              @asm.label(past)
            end
            @asm.bra(done)
            emit_keyed_move(keyed, mover, shown)
            @asm.label(done)
          end

          # The first entry showing's number into D2, and on to the compare of the place after it; on
          # to +done+ when one or none shows. Where every entry shows, which is one test, that is the
          # first entry and the compare after it is the next.
          def emit_keyed_start_past_hidden(keyed, shown, starts, done)
            from_first = fresh("sort_from_first")
            @asm.tst(:w, at(shown.hidden))
            @asm.branch(:eq, from_first)
            @asm.cmp(:w, @asm.imm(keyed.count - 1), at(shown.hidden))
            @asm.branch(:ge, done)
            @asm.movea(:l, at(shown.bound), @asm.a(0))
            @asm.move(:w, @asm.ind(0), @asm.d(0))
            @asm.move(:l, @asm.idx(1, 0, 0, :w), @asm.d(2))
            emit_step_picked_by_hidden(shown, starts)
            @asm.label(from_first)
            @asm.move(:w, at(keyed.entries), @asm.d(0))
            @asm.move(:l, @asm.idx(1, 0, 0, :w), @asm.d(2))
          end

          # The item in D0, with its number in D1, at the place D3 names (twice it), moved back past
          # every item before it whose number is strictly beyond its own, each of those a place on. A3
          # walks back from the place; D4 is the item before it, D5 that one's number. The number before
          # the place the item started in, in D2, is still the number before the next place, since
          # that place now holds the item that was before it. For a sort handed +shown+ the walk back
          # stops at the first entry showing, whose address is kept (ShownSort::Kept#bound).
          def emit_keyed_move(keyed, mover, shown = nil)
            back = fresh("sort_back")
            place = fresh("sort_place")
            stop = keyed.descending ? :ge : :le # the number before is not beyond the item's: it stops
            @asm.label(mover)
            @asm.lea(at(keyed.entries), @asm.a(3))
            @asm.add(:w, @asm.d(3), @asm.a(3))
            @asm.label(back)
            @asm.move(:w, @asm.disp(3, -2), @asm.d(4))
            @asm.move(:l, @asm.idx(1, 0, 4, :w), @asm.d(5))
            @asm.cmp(:l, @asm.d(1), @asm.d(5))
            @asm.branch(stop, place)
            @asm.move(:w, @asm.d(4), @asm.ind(3))
            @asm.subq(:l, 2, @asm.a(3))
            @asm.cmp(:l, shown ? at(shown.bound) : @asm.imm(keyed.entries), @asm.a(3))
            @asm.branch(:ne, back)
            @asm.label(place)
            @asm.move(:w, @asm.d(0), @asm.ind(3))
            @asm.rts
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
          #
          # An index that is a loop's variable known to stay inside the table (ControlFlow#index_below)
          # is read as it is, with nothing to make safe.
          def value_of_table_get(node)
            table = @tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            count = table.values.length
            bytes, signed = table_keeping(table)
            value(index_inside?(node.index, count) ? node.index : LoweringPlan.index_kept_in_range(node.index, count))
            base = @tables_held&.fetch(node.name, nil)
            @asm.lea(@asm.abs_l(table_label(table.name)), @asm.a(0)) unless base
            emit_table_entry(bytes, signed, count * bytes <= 0x7FFF ? :w : :l, base || 0)
          end

          # D0 the entry the index in D0 names in the table A(+base+) points at (A0 unless the table is
          # held, Bends#emit_bend_rows_held), widened by its size and sign.
          # The index is inside the table by now, so one whose entries end within 32K is scaled and
          # added as a word (+index_size+ :w), which is quicker. An entry with no sign is read into
          # D1, emptied first, and moved across: fewer cycles than reading it into D0 and masking
          # off what the index left above it.
          def emit_table_entry(bytes, signed, index_size, base = 0)
            (bytes.bit_length - 1).times { @asm.add(index_size, @asm.d(0), @asm.d(0)) }
            entry = @asm.idx(base, 0, 0, index_size)
            return @asm.move(:l, entry, @asm.d(0)) if bytes == 4

            size = Runtime::Lists::SLOT_SIZES.fetch(bytes)
            unless signed
              @asm.moveq(0, @asm.d(1))
              @asm.move(size, entry, @asm.d(1))
              return @asm.move(:l, @asm.d(1), @asm.d(0))
            end
            @asm.move(size, entry, @asm.d(0))
            emit_slot_widening(bytes)
          end

          # --- timers ---
          #
          # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
          # doing, and runs what the game gave it to do on each tick. A frame is the interpreter's
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

          # The routines the runtime runs at each frame boundary: one that moves every running timer
          # on, in the order the timers were first started, and one for each timer, which moves it on
          # and runs its handler. None for a game with no timers.
          def timer_sections
            return [] if @timers.empty?

            each_timer = @timers.flat_map { |name, _| with_tick_handler_numbers_recorded(name) { timer_section(name) } }
            @frame_begins = "timers frame"
            in_order = routine_section(@frame_begins, [], routine: "the timers") do
              with_call_numbers_kept(numbers_kept_around_timers(@timer_crossed)) do
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

          # Jump to +label+ when +condition+ holds. A comparison jumps on the flags it leaves, by the
          # one branch that reads them; and a test that something is nought (`x == 0`, which is how a
          # `while` asks whether its own test has stopped holding) is the jump unless that something
          # holds, with no 1 or 0 made of it on the way.
          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.bra(label) if known

            inner = operand_tested_for_nought(condition)
            return jump_unless(inner, label) if inner

            if comparison?(condition)
              emit_compare(condition)
              return @asm.branch(HOLDS_WHEN.fetch(condition.op), label)
            end

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            @asm.bra(label)
            @asm.label(go_on)
          end

          def comparison?(node) = node.is_a?(Node) && node.kind == :binop && COMPARISONS.include?(node.op)

          # The X of a test `X == 0` (or `0 == X`), which holds exactly when X does not; or nil.
          def operand_tested_for_nought(node)
            return unless binop?(node, :==)
            return node.lhs if folded(node.rhs)&.zero?

            node.rhs if folded(node.lhs)&.zero?
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on the flags it leaves, without
          # making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.bra(label) if known.zero?) if known

            inner = operand_tested_for_nought(condition)
            return jump_if(inner, label) if inner

            if binop?(condition, :and) && Unchanging.value?(condition.rhs) { |part| folded(part) }
              # The interpreter works both sides out (Reference#eval_binop); the second is skipped here
              # when the first does not hold only where working it out changes nothing (IR::Unchanging). A
              # side that reads a list can stop the game (an index out of range), so it is worked out
              # whatever the first side gives, by the value below.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif comparison?(condition)
              emit_compare(condition)
              @asm.branch(FAILS_WHEN.fetch(condition.op), label)
            else
              emit_test_for_nought(condition)
              @asm.branch(:eq, label)
            end
          end

          # The flags of +operand+ against nought: a variable tested where it is kept, anything else
          # worked out first.
          def emit_test_for_nought(operand)
            name = variable_named(operand)
            return @asm.tst(:l, var(name)) if name

            value(operand)
            @asm.tst(:l, @asm.d(0))
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          # The two sides of a comparison compared: the left side's flags against the right (CMP),
          # which the branch that follows reads. A variable against a number written in the program
          # is compared where it is kept, one instruction and no load; and anything against nought is
          # a TST, which leaves the flags a CMP with nought does and has no number to read.
          def emit_compare(node)
            number = folded(node.rhs)
            return with_right_operand(node.lhs, node.rhs) { |right| @asm.cmp(:l, right, @asm.d(0)) } unless number
            return emit_test_for_nought(node.lhs) if number.zero?

            name = variable_named(node.lhs)
            return @asm.cmp(:l, @asm.imm(number), var(name)) if name

            value(node.lhs)
            @asm.cmp(:l, @asm.imm(number), @asm.d(0))
          end

          # --- values: each leaves its number in D0 ---

          # A value the lowering makes for itself beside the IR's: where a label is.
          LabelAddress = Data.define(:label)

          def value(operand)
            known = folded(operand)
            return load_constant(known) if known

            case operand
            when Symbol then load_variable(operand)
            when Node then value_of_kind(operand)
            when LabelAddress then @asm.move(:l, @asm.imm(operand.label), @asm.d(0))
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def value_of_int(node) = load_constant(node.value)

          # The first player, and each one after up to the highest whose button has been down
          # (Runtime::Frame::PLAYERS_PAST_FIRST, which never falls).
          def value_of_players_connected(_node)
            @asm.moveq(0, @asm.d(0))
            @asm.move(:w, runtime_at(Runtime::Frame::PLAYERS_PAST_FIRST), @asm.d(0))
            @asm.addq(:l, 1, @asm.d(0))
          end

          # A cartridge is played by one person, the first player.
          def value_of_local_player(_node) = load_constant(1)
          def value_of_var_ref(node) = load_variable(node.name)

          # One byte of a named blob of data, which the game sets where to look in as it is built, so it is a number
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
            held = held_product(node)
            return @asm.move(:l, held, @asm.d(0)) if held
            return value_of_comparison(node) if COMPARISONS.include?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)
            return if %i[<< >>].include?(node.op) && emit_shift_by_number(node)
            return if node.op == :* && (emit_product_by_written_number(node) || emit_product_by_comparison(node))
            return if node.op == :/ && emit_divide_by_number(node)
            return if node.op == :% && emit_remainder_by_number(node)

            return runtime_call(CALLED_SUMS.fetch(node.op), [node.lhs, node.rhs]) if CALLED_SUMS.key?(node.op)

            left, right = sides_in_cheapest_order(node)
            with_right_operand(left, right) do |operand|
              next if emit_sum_with_number(node.op, operand)

              # EOR takes only a register or a number as its source.
              if node.op == :^ && operand.mode != :dn && operand.mode != :imm
                @asm.move(:l, operand, @asm.d(1))
                operand = @asm.d(1)
              end
              emit_long_sum(node.op, operand, @asm.d(0))
            end
          end

          # The sums that come to the same whichever side is worked out first.
          EITHER_WAY_ROUND = %i[+ & | ^].freeze

          # [left, right] of the sum +node+, the other way round where that is the same sum and only
          # the left side is a number or a variable: `4 + (t & 31)` is then `t & 31` worked out and 4
          # added to it, where as written the right side is worked out, pushed, and pulled back to be
          # added to a 4 loaded for it. Neither order changes what is read: a side that needs working
          # out is worked out first as written too (#with_right_operand).
          def sides_in_cheapest_order(node)
            return [node.lhs, node.rhs] unless EITHER_WAY_ROUND.include?(node.op) && operand_of(node.lhs) && !operand_of(node.rhs)

            [node.rhs, node.lhs]
          end

          # D0 and a number written in the program (+operand+), the short ways: nothing at all for a
          # sum that changes nothing (`+ 0`, which the builder's own sums are full of), ADDQ or SUBQ
          # for 1 to 8, and for any other number that fits MOVEQ, the number put in D1 and the sum
          # made from there, a word shorter and a quarter quicker than the number as a long word in
          # the instruction. True when it was done so.
          def emit_sum_with_number(operator, operand)
            return false unless operand.mode == :imm && operand.value.is_a?(Integer) && operand.plus.to_i.zero?

            number = operand.value
            return true if number.zero? && %i[+ - | ^].include?(operator)
            return true if number == -1 && operator == :&

            number = -number if operator == :- && number.between?(-8, 8)
            operator = :+ if operator == :- && number.between?(-8, 8)
            if operator == :+ && number.between?(1, 8)
              @asm.addq(:l, number, @asm.d(0))
            elsif operator == :+ && number.between?(-8, -1)
              @asm.subq(:l, -number, @asm.d(0))
            elsif number.between?(-128, 127)
              @asm.moveq(number, @asm.d(1))
              emit_long_sum(operator, @asm.d(1), @asm.d(0))
            else
              return false
            end
            true
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
            node.op == :and ? @asm.and(:l, @asm.d(1), @asm.d(0)) : @asm.or(:l, @asm.d(1), @asm.d(0))
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
            most = folded(node.max)
            return emit_hold_from_nought_to(most) if folded(node.min)&.zero? && most && !most.negative?

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

          # D0 held from nought to +most+, a number written in the program: what a table's index is
          # held to. Read with no sign, a number below nought is far past +most+, so one compare
          # finds a number already inside, and that is all a number inside costs: the compare and a
          # short branch over the rest. For one outside, D0 is made all ones if it was nought or
          # more and nought if it was below, and that taken with +most+ is the end it is held to.
          # D1 is worked with.
          def emit_hold_from_nought_to(most)
            emit_operand_load(@asm.imm(most), 1)
            @asm.cmp(:l, @asm.d(1), @asm.d(0))
            @asm.branch_over(:ls, HOLD_TO_END_BYTES)
            @asm.tst(:l, @asm.d(0))
            @asm.scc(:pl, @asm.d(0))
            @asm.ext(:w, @asm.d(0))
            @asm.ext(:l, @asm.d(0))
            @asm.and(:l, @asm.d(1), @asm.d(0))
          end

          # The five instructions after the branch in #emit_hold_from_nought_to, a word each.
          HOLD_TO_END_BYTES = 10

          # A shift right by a number written in the program is one instruction; any other count is
          # the runtime's shift.
          def value_of_shift_right(node)
            return if node.bits.is_a?(Integer) && node.bits.between?(0, 31) && emit_shift(node.operand, :asr, node.bits)

            runtime_call("rt_shr32", [node.operand, Build.int(node.bits)])
          end

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # The buttons held, or pressed, through the pass: a bit each, in IR::Buttons's order, and
          # any of them for Buttons::ANY; each other player's pad's for `player: 2` to 4, and every pad
          # the game reads for `player: :any` (Runtime::Frame::OTHER_CONTROLLERS).
          def value_of_held(node) = emit_button_truth([Runtime::Frame::HELD] + Runtime::Frame::OTHER_CONTROLLERS.map(&:held), node)
          def value_of_pressed(node) = emit_button_truth([Runtime::Frame::PRESSED] + Runtime::Frame::OTHER_CONTROLLERS.map(&:pressed), node)

          # +words+ is where each player's buttons are kept, the first player's first.
          def emit_button_truth(words, node)
            button = node.button
            mask = if button == Buttons::ANY
                     Buttons.mask(Console::GENESIS.buttons)
                   else
                     1 << (Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}")
                   end
            if node.player == Buttons::ANY
              read = words.select { |name| @memory.reserved?(name) }
              @asm.move(:w, runtime_at(read.first), @asm.d(0))
              read.drop(1).each { |name| @asm.or(:w, runtime_at(name), @asm.d(0)) }
            else
              @asm.move(:w, runtime_at(words.fetch(node.player - 1)), @asm.d(0))
            end
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
            return var(name) if name

            held_product(node) || held_word_field(node) || fixed_word_slot(node)
          end

          # A long slot of a list at an address known here (#fixed_slot), kept as it is, which an
          # instruction reads where it is as it would a variable; nil for anything else.
          def fixed_word_slot(node)
            return unless node.is_a?(Node) && node.kind == :list_get && slot_place(node.name).scale == 1

            address, bytes = fixed_slot(node)
            at(address) if bytes == 4
          end

          # A long field of the thing a walk holds (#held_field), which an instruction reads where it is
          # as it would a variable; nil for anything else.
          def held_word_field(node)
            return unless node.is_a?(Node) && node.kind == :list_get && @held_walk
            return unless slot_bytes(node) == 4 && slot_place(node.name).scale == 1

            held_field(node)
          end

          # The left side worked out into D0, and the block handed where the right side is: in place
          # when it needs nothing worked out, and otherwise worked out first and kept while the left
          # side is worked out.
          #
          # It is kept in D2 where the left side is written in place, with no call
          # (#value_keeps_counters?), and no sum round this one is keeping its right side there
          # already: a move there and none back, where the stack takes a push and a pull of twelve
          # cycles each. A sum inside the left side then pushes its own. Anywhere else the right side
          # is pushed, and pulled into D1 once the left side is in D0.
          def with_right_operand(left, right)
            operand = operand_of(right)
            if operand
              value(left)
              return yield(operand)
            end

            unless @right_side_kept || !value_keeps_counters?(left)
              value(right)
              @asm.move(:l, @asm.d(0), @asm.d(2))
              @right_side_kept = true
              begin
                value(left)
              ensure
                @right_side_kept = false
              end
              return yield @asm.d(2)
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
              emit_long_shift(how, count)
            elsif count > 8
              @asm.moveq(count, @asm.d(1))
              emit_long_shift(how, @asm.d(1))
            end
          end

          # D0 shifted by +by+ (a count of 1 to 8, or a register): left (:lsl), or right keeping its
          # sign (:asr).
          def emit_long_shift(how, by)
            case how
            when :lsl then @asm.lsl(:l, by, @asm.d(0))
            when :asr then @asm.asr(:l, by, @asm.d(0))
            else raise LoweringError, "#{how.inspect} is not a shift written here"
            end
          end

          # A runtime routine taking +args+ in D0, D1, D2... Each that needs working out is worked out
          # in order and pushed, then they are pulled into their registers, the last first; then the
          # ones that are only a number or a variable are put in theirs. A block given writes what
          # else the routine takes, last before the call.
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
            yield if block_given?
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
