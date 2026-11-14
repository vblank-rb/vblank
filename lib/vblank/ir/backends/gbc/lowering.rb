# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # ONE PROGRAM, LOWERED STRAIGHT TO SM83 MACHINE CODE: the Color's peer of the GBA lowering,
        # which does the same in ARM. It walks the IR with a table naming the method for each kind of
        # statement and each kind of value (the interpreter's own shape, Reference), and emits the
        # instructions through the encoder (SM83), calling the runtime (GBC::Runtime) for what the
        # runtime does: the 32-bit arithmetic, the frame, the buttons.
        #
        # HOW A NUMBER IS WORKED OUT. Every value leaves its answer in the four registers B C D E, B
        # the top byte, which is where every runtime routine takes and gives a number. A sum of two
        # works out the right-hand side first and pushes it on the stack — which then holds it lowest
        # byte first, as a number sits in memory — works out the left-hand side, and hands the
        # routine the right one's address (HL = SP). A routine taking several numbers has them all
        # pushed, the first deepest (Runtime::Calls). Nothing is kept in a register from one
        # statement to the next, so a statement never has to know what came before it.
        #
        # WHERE THINGS LIVE. The game's variables, and each routine's own numbers — a loop's count, a
        # `case`'s reading — are places in work memory (Memory), fixed while the program is built, so
        # a routine cannot call itself, and a program in which one can is refused. Tables go in the
        # part of the cartridge always in view; routines go in the banks, and one in another bank is
        # called through bank 0 (Runtime::Calls's rt_far_call).
        #
        # It makes the kinds in its two tables, and refuses by name a program that reaches one it does
        # not make yet (NOT_LOWERED_YET), and one a Color cannot do at all in the words its answers
        # have (Console::Answers#refusals).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the
          # +part+ of the build that is missing, for a test run to count skips by — the Super
          # Nintendo's the same (Backends::NotMadeYet).
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          include ControlFlow

          # EVERY KIND THIS LOWERING WRITES: its own, each by a method called by name in
          # #emit_statement and #value_of_kind, and each part's (Picture, Sound and the rest, and the
          # loops and tests every cartridge lowering shares, ControlFlow), which each part writes in a
          # case of its own. A declaration writes nothing where it is. Read by
          # test_gbc_kind_coverage.rb.
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp call call_one_of
            halt wait_vblank list_new list_push list_drop list_set list_fill list_copy list_sort
            save_init save_store save_write save_erase save_load_list save_store_list timer_start timer_stop
            on_timer show_light_now show_held_tiles
          ] + ControlFlow::STATEMENT_KINDS + Picture::STATEMENT_KINDS + Sound::STATEMENT_KINDS + Clock::STATEMENT_KINDS +
            TileRuns::STATEMENT_KINDS + SpriteTiles::STATEMENT_KINDS + Nodes.of_role(:declaration)).freeze

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
            when :save_init then emit_save_init(node)
            when :save_store then emit_save_store(node)
            when :save_write then emit_save_write(node)
            when :save_erase then emit_save_erase(node)
            when :save_load_list, :save_store_list then emit_save_list_move(node)
            when :timer_start then emit_timer_start(node)
            when :timer_stop then emit_timer_stop(node)
            # a timer's handler runs as its timer ticks, not where it is written
            when :on_timer then emit_nothing(node)
            # the light is not made yet (shade_outside), and a game without one works nothing out again
            when :show_light_now then emit_nothing(node)
            # a pass's cell changes already wait for the gap between frames here, so a held
            # background's need nothing more (Console::ColorAnswers, `background`)
            when :show_held_tiles then emit_nothing(node)
            when *Picture::STATEMENT_KINDS then emit_picture_statement(node)
            when *Sound::STATEMENT_KINDS then emit_sound_statement(node)
            when *Clock::STATEMENT_KINDS then emit_clock_statement(node)
            when *TileRuns::STATEMENT_KINDS then emit_tile_runs_statement(node)
            when *SpriteTiles::STATEMENT_KINDS then emit_sprite_tiles_statement(node)
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
            int var_ref binop neg bit_not absolute clamped mul_fix div_fix shift_right held pressed list_get
            list_len table_get save_read save_sum timer_ticks chance data_byte players_connected local_player
          ] + Picture::VALUE_KINDS + Clock::VALUE_KINDS).freeze

          def value_of_kind(node)
            case node.kind
            when :int then value_of_int(node)
            when :var_ref then value_of_var_ref(node)
            when :binop then value_of_binop(node)
            when :neg then value_of_neg(node)
            when :bit_not then value_of_bit_not(node)
            when :absolute then value_of_absolute(node)
            when :clamped then value_of_clamped(node)
            when :mul_fix then value_of_mul_fix(node)
            when :div_fix then value_of_div_fix(node)
            when :shift_right then value_of_shift_right(node)
            when :held then value_of_held(node)
            when :pressed then value_of_pressed(node)
            when :list_get then value_of_list_get(node)
            when :list_len then value_of_list_len(node)
            when :table_get then value_of_table_get(node)
            when :save_read then value_of_save_read(node)
            when :save_sum then value_of_save_sum(node)
            when :timer_ticks then value_of_timer_ticks(node)
            when :chance then value_of_chance(node)
            when :data_byte then value_of_data_byte(node)
            when :players_connected then value_of_players_connected(node)
            when :local_player then value_of_local_player(node)
            when *Picture::VALUE_KINDS then value_of_picture_kind(node)
            when *Clock::VALUE_KINDS then value_of_clock_kind(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          include Picture
          include PaintReach
          include Sound
          include TileRuns
          include SpriteTiles
          include Clock
          include WrittenNumbers
          include Division
          include KeptVariables

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list the
          # day the Color does it; test_gbc_kind_coverage.rb holds the list and the kind lists above to
          # every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({})

          # How many bytes of save memory a read or a write moves, by the width it names.
          SAVE_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4 })

          # The number the runtime knows each way of keeping an entry by (Runtime::Lists' copy reads
          # it), and the routine that reads an entry kept that way, by its bytes and its sign
          # (LoweringPlan#table_keeping).
          TABLE_KEPT = Ractor.make_shareable({ [1, true] => [0, "rt_read_int8"], [1, false] => [1, "rt_read_uint8"],
                                               [2, true] => [2, "rt_read_int16"], [2, false] => [3, "rt_read_uint16"],
                                               [4, true] => [4, "rt_read_int32"] })

          # The runtime's quick push and read for a list whose slots are this many bytes
          # (Runtime::Lists#emit_queue_routines); a list of whole numbers goes the long way.
          NARROW_LIST_ROUTINES = Ractor.make_shareable({ 1 => %w[rt_byte_list_push rt_byte_list_item],
                                                         2 => %w[rt_half_list_push rt_half_list_item] })

          # The registers a number in BCDE is held in, its lowest byte first, as memory keeps it.
          BCDE_LOW_FIRST = %i[e d c b].freeze

          # The runtime's sums on BCDE and the number at HL, by the operator of a binop.
          SUMS = Ractor.make_shareable({ :+ => "rt_add32", :- => "rt_sub32", :* => "rt_mul32", :/ => "rt_div32",
                                         :% => "rt_mod32", :& => "rt_and32", :| => "rt_or32", :^ => "rt_xor32",
                                         :<< => "rt_shl32", :>> => "rt_shr32", and: "rt_both32", or: "rt_either32" })

          # A comparison, by what rt_cmp32 leaves in A (0 equal, 1 less, 2 greater): the number A is
          # compared with, and whether the comparison holds when they are equal (:z) or not (:nz).
          COMPARISONS = Ractor.make_shareable({ :< => [1, :z], :<= => [2, :nz], :> => [2, :z], :>= => [1, :nz],
                                                :== => [0, :z], :!= => [0, :nz] })

          # What the game's code is to the author, for a cartridge too full for it (Linker::TooBig).
          DATA = SM83::Holding.new(what: "the game's tables and its variables' starting values",
                                   fix: "make its tables shorter, or use fewer of them")
          ROUTINES = SM83::Holding.new(what: "the game's routines", fix: "make its routines shorter, or use fewer of them")

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          # The game's routines, each section's label beside what that routine is to the author — a
          # scene or a routine by the name the game gave it, the game loop, a timer — once #sections
          # has made them. A part of a routine cut to fit a bank is that routine.
          attr_reader :section_routines

          # Values this lowering makes for itself beside the IR's, each worked out into BCDE as one of
          # the IR's is: where a label is (a table a runtime routine reads), and where with the bank
          # of the cartridge it is in above it (a table a runtime routine puts in view to read); the
          # entry of a table of the drawing's numbers at an index, +bytes+ wide and read with its
          # sign or not; what a runtime routine gives back for +args+; and a sum or a test of two of
          # any of these, as a binop of the IR's is worked out.
          Address = Data.define(:label)
          BankedAddress = Data.define(:label)
          # An Entry of a +banked+ table is read with the table's bank put in view (rt_far_read).
          Entry = Data.define(:label, :bytes, :signed, :index, :banked) do
            def initialize(label:, bytes:, signed:, index:, banked: false) = super
          end
          RuntimeValue = Data.define(:routine, :args)
          Sum = Data.define(:op, :lhs, :rhs)

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # Where each of the game's variables went, by its name, and each of its lists — [its place,
          # its capacity, the bytes a slot, its name] — once #sections has placed them; and the label
          # of the routine the runtime runs at each frame boundary, or nil for a game with no timers.
          attr_reader :variables, :lists, :frame_begins

          # +lends_sprite_colors+ builds the game with its sprites' lists of colours borrowing the
          # console's eight as it runs (Art::TooManySpriteLists), and :by_scene with each scene numbering
          # its own lists too (Art::TooManyLentLists). +tile_rooms+ builds it with each screen
          # bringing its own background tiles in (Art::TooManyBackgroundTiles, Picture#plan_tile_rooms),
          # and +room_colors+ with its own background colours too (Art::TooManyBackgroundLists).
          # +banked_songs+ keeps its songs' notes in the cartridge's banks (GBC::Music#sections), and
          # +bank_pose_tables+ the tables of its sprites' poses in each list (Picture#picture_and_attributes_drawn),
          # and +bank_background_colors+ the tables of its backgrounds' colours (Picture#emit_background_colors_for_declaration).
          # +banked_table_bytes+ is how big one of the game's tables has to be to go to a bank (#banked_tables).
          # +effects_in_banks+ keeps its sound effects there too (GBC::Music#effects_in_banks?), and
          # +indexes_in_banks+ the tables that give where each song, picture, screen and routine is
          # (GBC#build_in_view).
          # +cache+ holds what is worked out from +program+ alone, kept from one try at a build to
          # the next (BuildCache): nothing in it depends on how this one is built.
          # +scene_pictures+ marks that each scene brings its own sprite pictures in (Art::TooManySpriteTiles),
          # which takes rooms: of nothing but those pictures, unless +tile_rooms+ marks that the backgrounds
          # need rooms too.
          def initialize(program, memory:, lends_sprite_colors: false, tile_rooms: false, room_colors: false,
                         banked_songs: false, bank_pose_tables: false, bank_background_colors: false,
                         scene_pictures: false, banked_table_bytes: BANKED_TABLE_BYTES, effects_in_banks: false,
                         indexes_in_banks: false, cache: BuildCache.for(GBC, program))
            @program = program
            @effects_in_banks = effects_in_banks
            @indexes_in_banks = indexes_in_banks
            @banked_table_bytes = banked_table_bytes
            @cache = cache
            @plans_scene_pictures = scene_pictures
            @memory = memory
            @lends_sprite_colors = lends_sprite_colors
            @banked_songs = banked_songs
            @bank_pose_tables = bank_pose_tables
            @bank_background_colors = bank_background_colors
            @plans_tile_rooms = tile_rooms || scene_pictures # each screen brings its own in (Picture#plan_tile_rooms)
            @plans_background_rooms = tile_rooms # ...its background tiles among them
            @plans_room_colors = room_colors
            # What the program is before any instruction is made, worked out as the Super Nintendo's
            # is (LoweringPlan), once a build, and kept here under the names the rest of the
            # lowering reads.
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
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @cuts = RoutineCuts.for(self, cache)
            @section_routines = {} # each routine's section, by its label -> what it is to the author
            prepare_picture
            prepare_sound
            prepare_clock
          end

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            @plan.refuse_unbuildable!(not_lowered_yet: NOT_LOWERED_YET, not_made_yet: NotMadeYet, makes_followed_lists: false)
            refuse_unsupported_save_memory!
            refuse_unfit_paint_squares!
            refuse_lists_in_use_past_eight!
            refuse_rumble_beside_clock!
            # ...and the ones a game loop keeps of its own in the Color's order (IR::Frames::ConsoleLoop).
            loops = game_loops.flat_map { |node| console_loop(node).variables }
            (Reach.variables(@program) | loops).each do |name|
              @variables[name] = @memory.reserve("the variable #{name.inspect}", kept_bytes(name) || 4)
            end
            @declared_lists.each_value do |node|
              next if held_run_on_list(node.name)

              width = LoweringPlan::SLOT_BYTES.fetch(node.width)
              # Named as the game names it, since running out of room says which list asked.
              place = @memory.reserve("the list #{node.name.inspect}", Runtime::Lists::HEADER + (node.capacity * width))
              @lists[node.name] = [place, node.capacity, width, node.name.to_s]
            end
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            keep_held_colors
            keep_group_numbers
            keep_sprites_hidden_flag
            keep_corner_notes
            keep_loop_running
            keep_patches
            keep_tile_runs
            keep_drawn_palettes
            keep_background_colors_held
            keep_big_map_places
            keep_column_numbers
            keep_clock_readings
            routines = @called.flat_map do |name|
              with_call_numbers_recorded_for(name) do
                routines_fitting(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
              end
            end
            timers = timer_sections
            bend_routine = bend_sections
            main = routines_fitting(MAIN, [*clock_at_power_on, *@program.children], routine: "the game loop")
            # The routines the drawing asked for as the rest was made, and then the data last of
            # all, since the routines are what find the tables in it.
            columns = column_sections
            [data_section, *banked_table_sections, *routines, *timers, *bend_routine, *main, *clock_sections, *columns]
          end

          # The names of the tables a list is filled from, which stay in view however big they are
          # (#banked_tables).
          def tables_copied_to_lists = @reachable.filter_map { |node| node.table if node.kind == :list_copy }

          # DOES THE GAME COUNT THE FRAMES ITS SCREEN IS OFF FOR, from power-on to its first frame
          # (Runtime::Frame#emit_dark_start)? A game that reads `frames_since_power_on` and waits for
          # the screen does, so that setting up counts as it does on the Advance. The timer counts
          # them, and in a game that plays a recording the timer is the recording's, so such a game
          # counts from its first frame.
          def counts_dark_frames?
            @program.walk.any? { |node| node.kind == :var_ref && node.name == Frames::COUNT } &&
              @program.walk.any? { |node| node.kind == :wait_vblank }
          end

          # Whether the game divides by a byte written in it (Division#emit_divide_by_number), so its
          # runtime carries the routines that do that. Asked once the game's routines are made.
          def divides_by_written_bytes? = @divides_by_written_bytes || false

          # Whether the game holds a number between ends of up to two bytes (#value_of_clamped), so
          # its runtime carries rt_clamp16_outside. Asked once the game's routines are made.
          def clamps_outside? = @clamps_outside || false

          # Does the game declare a list of bytes full, or fill one? Then its runtime carries the
          # quick way to do it, and a game that does neither builds without it.
          def fills_byte_lists?
            lists = @program.walk.select { |node| node.kind == :list_new && node.width == :byte }
            names = lists.map(&:name)
            lists.any?(&:full_of) || @program.walk.any? { |node| node.kind == :list_fill && names.include?(node.name) }
          end

          # Whether the game pushes bytes or takes from a list's front, so wants the routines that do
          # those quickly (Runtime::Lists#emit_queue_routines).
          def keeps_queues?
            bytes = @program.walk.select { |node| node.kind == :list_new && node.width == :byte }.map(&:name)
            @program.walk.any? do |node|
              (node.kind == :list_push && bytes.include?(node.name)) || (node.kind == :list_drop && node.from == :front)
            end
          end

          # Whether the game moves a whole list to or from save memory, so wants the routines that do
          # it as a block (Runtime::Lists#emit_save_moves).
          def moves_lists_to_save? = SaveListMoves.moved_in?(@program)

          # Whether the game pushes onto a list of halves or takes from one's front, so wants the
          # routines that push and read such a list quickly (Runtime::Lists#emit_queue_routines).
          def keeps_half_queues?
            halves = @program.walk.select { |node| node.kind == :list_new && node.width == :half }.map(&:name)
            @program.walk.any? do |node|
              (node.kind == :list_push || (node.kind == :list_drop && node.from == :front)) && halves.include?(node.name)
            end
          end

          # How many bytes +list+ comes to, made on its own and thrown away. The Color measures its own
          # way rather than on copies of its state, and MeasuredOnCopies::OWN_WAYS gives the reason.
          def bytes_of(list)
            saved = [@asm, @routine, @labels, @constants, @routine_data, @locals.dup, @drawing_tables.length]
            @measuring = true
            @measured = []
            @asm = SM83.new("measuring", home: :banked)
            @labels = 0
            @constants = {}
            @routine_data = {}
            list.each { |node| statement(node) }
            @asm.here + @constants.keys.sum { |value| Array(value).length * 4 } + routine_data_bytes
          ensure
            @measuring = false
            @asm, @routine, @labels, @constants, @routine_data, @locals, tables = saved
            @drawing_tables.slice!(tables..)
          end

          private

          # --- refusals: the Color's own, after the ones every cartridge lowering makes (LoweringPlan#refuse_unbuildable!) ---

          # A Game Boy Color cartridge saves in 32K of battery-backed memory (Runtime::Saving): a game
          # that asks for flash, an EEPROM or more memory is refused, naming what it asked for.
          def refuse_unsupported_save_memory!
            return unless SaveLayout.named_by?(@program)

            memory = SaveLayout.memory_of(@program)
            return if memory.chip == :battery && memory.size == Runtime::Saving::SIZE

            raise LoweringError, "this game saves in #{memory.kilobytes}K of #{memory.kind_words}, and a Game Boy Color " \
                                 "cartridge saves in 32K of battery-backed memory. To fix this, leave `save_memory:` " \
                                 "out of VBlank.game, or say 32."
          end

          # --- the data: in bank 0, where every routine can read it ---

          # The tables a run reads, the tables of routines a call picks from by number, the places
          # that do not start at nought, and each list's place, capacity and slot (Runtime#emit_start
          # reads the last two).
          def data_section
            asm = SM83.new("game data", home: :fixed, holds: DATA)
            tables_read.each do |table|
              next if held_picture_table?(table)

              if banked_tables.include?(table.name)
                asm.label(table_parts_label(table.name))
                table_parts(table).each_index do |part|
                  asm.data_words(table_part_label(table.name, part))
                  asm.data_bank_of(table_part_label(table.name, part))
                end
                next
              end

              asm.label(table_label(table.name))
              table_parts(table).each { |part| asm.data_bytes(part) }
            end
            @drawing_tables.reject(&:banked).each { |table| emit_drawing_table(asm, table) }
            emit_group_slots(asm)
            emit_together_records(asm)
            @routine_tables.each do |targets, label|
              asm.label(label)
              targets.each do |name|
                routine = self.class.routine_label(name)
                asm.data_words(routine)
                asm.data_bank_of(routine)
              end
            end
            asm.label("game_starts")
            @starts.each do |address, value|
              asm.data_words(address)
              asm.data_bytes(little_endian(value, 4))
            end
            asm.data_words(0)
            asm.label("game_lists")
            @lists.each_value do |place, capacity, width, _|
              asm.data_words(place)
              asm.data_words(capacity)
              asm.data_bytes(width)
            end
            asm.data_words(0)
            asm.section
          end

          def tables_read = @plan.tables_read

          def table_label(name) = "table #{name}"

          def table_parts_label(name) = "table #{name} parts"
          def table_part_label(name, part) = "table #{name} part #{part}"

          # THE TABLES KEPT OUT OF THE PART ALWAYS IN VIEW. That part is 16 kilobytes and holds the
          # runtime and everything read without switching a bank in, so a big table there — the
          # walls of a hundred-cell-square room are ten thousand bytes — leaves no room for the
          # rest. A table at least this big is kept in banks instead, cut into parts so that one
          # bigger than a bank still fits (Runtime::Calls::TABLE_PART_BYTES), and a read of it
          # finds its part and puts that part's bank in view (rt_far_read_parts): a few dozen more
          # instructions a read, and none for a small table. A table a list is filled from stays
          # in view, since the list's copy reads it in a loop of its own.
          BANKED_TABLE_BYTES = 1024

          # MANY SMALLER TABLES CAN COME TO THE SAME. A game they do not fit in view for is built
          # again with tables of each of these sizes going to banks too, the bigger first, so its
          # short tables are the last to pay for a read. Below the last, a table's place in the
          # list of parts would take nearly what the table does.
          SMALLER_BANKED_TABLE_BYTES = [256, 16].freeze

          # The names of the tables kept in banks of their own.
          def banked_tables
            @banked_tables ||= begin
              copied = tables_copied_to_lists
              tables_read.filter_map do |table|
                next if copied.include?(table.name)

                bytes, = table_keeping(table)
                table.name if bytes * table.values.length >= @banked_table_bytes
              end
            end
          end

          # A section for each part of each table kept in banks.
          def banked_table_sections
            held = tables_read.select { |table| held_picture_table?(table) }.map { |table| held_pictures_section(table) }
            held += sprite_tiles_sources.map { |table| sprite_tiles_source_section(table) }
            tables = tables_read.select { |table| banked_tables.include?(table.name) }.flat_map do |table|
              table_parts(table).each_with_index.map do |bytes, part|
                asm = SM83.new(table_part_label(table.name, part), home: :banked, holds: DATA)
                asm.label(table_part_label(table.name, part))
                asm.data_bytes(bytes)
                asm.section
              end
            end
            drawings = @drawing_tables.select(&:banked).map do |table|
              asm = SM83.new(table.label, home: :banked, holds: DATA)
              emit_drawing_table(asm, table)
              asm.section
            end
            held + tables + drawings
          end

          # A table of the drawing's numbers (Picture#drawing_table), each entry its low bytes.
          def emit_drawing_table(asm, table)
            asm.label(table.label)
            table.entries.each { |entry| asm.data_bytes(little_endian(Int32.wrap(entry), table.bytes)) }
          end

          # +table+'s bytes as the cartridge keeps them, in parts of Runtime::Calls::TABLE_PART_BYTES.
          def table_parts(table)
            bytes, = table_keeping(table)
            kept = held_pictures_as_tiles(table) || table.values.flat_map { |entry| little_endian(Int32.wrap(entry), bytes) }
            kept.each_slice(Runtime::Calls::TABLE_PART_BYTES).to_a
          end

          def table_keeping(table) = @plan.table_keeping(table)

          def little_endian(value, size) = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }

          # --- routines ---

          # A routine of +body+'s statements, or of what the block emits for one this lowering makes
          # for itself. +routine+ is what it is to the author — a routine of the game's by its name,
          # the game loop, a timer — which a profile says its time by (#section_routines).
          def routine_section(label, body, routine:)
            @section_routines[label] = routine
            @asm = SM83.new(label, home: :banked, holds: ROUTINES)
            @routine = label
            @labels = 0
            @constants = {}
            @routine_data = {}
            @asm.label(label)
            body.each { |node| statement(node) }
            yield if block_given?
            @asm.ret
            @constants.each do |value, at|
              @asm.label(at)
              Array(value).each { |number| @asm.data_bytes(little_endian(number, 4)) }
            end
            emit_routine_data
            @asm.section
          end

          # DATA KEPT BESIDE THE CODE THAT READS IT, in a game whose indexes are in banks
          # (GBC#build_in_view): a list of routines a call picks from, a scene's record
          # of its own sprite lists. The routine's code runs in its own bank, which is in view while
          # it runs and while the runtime routines it calls read what it hands them, so data in the
          # same section is read with no bank put in view, and takes nothing of the part always in
          # view. Each routine that reads such a table keeps a copy of its own. +entries+ are
          # [:word, label] (where a label is) and [:bank, label] (the bank it is in), in order; the
          # label the data goes by is handed back.
          def routine_data_label(entries)
            @measured.each { |measured| measured.data << entries } if @measuring
            @routine_data[entries] ||= fresh("data")
          end

          ROUTINE_DATA_BYTES = Ractor.make_shareable({ word: 2, bank: 1 })

          def routine_data_bytes = @routine_data.keys.sum { |entries| entries.sum { |kind, _| ROUTINE_DATA_BYTES.fetch(kind) } }

          def emit_routine_data
            @routine_data.each do |entries, at|
              @asm.label(at)
              entries.each { |kind, label| kind == :word ? @asm.data_words(label) : @asm.data_bank_of(label) }
            end
          end

          def routine_said(name) = @plan.routine_said(name)

          # A label no other in the routine has: +what+ and the count, apart. Run together, a +what+
          # that ends in a number would make one label of two (not_colors_1 and 147, not_colors_11
          # and 47).
          def fresh(what)
            @labels += 1
            "#{@routine}.#{what}##{@labels}"
          end

          # A number of the routine's own, kept in work memory, by a name of its own that a value
          # can read as a variable. +start+ is what it holds from power-on. Code made only to be
          # measured (#bytes_of) is given a place that is never kept.
          def keep_local(what, start: 0)
            name = DerivedNames.local_number_name(@routine, what, @locals.length + 1)
            return name.tap { @locals[name] = Memory::FIRST } if @measuring

            @locals[name] = @memory.reserve("the game's number #{name}", 4)
            @starts << [@locals[name], start] unless start.zero?
            record_call_number(name, what)
            name
          end

          # The numbers each call of a routine keeps of its own (ControlFlow#call_numbers), put back
          # around the block's code, for every routine the frame boundary can call while a call of it is
          # waiting there (LoweringPlan#routines_reentered_at_frame_boundary): each pushed, four bytes,
          # before, and popped back after, so the call that waits goes on from its own loop's turn, as
          # the interpreter's does, whatever the boundary's call left there. A game whose boundary calls
          # no such routine has no code here.
          def with_call_numbers_kept
            return yield if call_numbers.empty?

            call_numbers.each do |name|
              value(name)
              @asm.push(:bc)
              @asm.push(:de)
            end
            yield
            call_numbers.reverse_each do |name|
              @asm.pop(:de)
              @asm.pop(:bc)
              store(name)
            end
          end

          # --- a routine too big for a bank, cut into parts ---

          # The most bytes one routine's code may come to before it is cut into parts, each a
          # routine of its own: a bank is 16K, and a routine and the numbers it uses go in one.
          MOST_ROUTINE_BYTES = 12_000

          # The most bytes a part cut off a routine may come to.
          MOST_PART_BYTES = 6_000

          # The routine +label+ of +body+'s statements, and the parts cut off it to fit a bank
          # (RoutineCuts#sections), each a section of its own.
          def routines_fitting(label, body, routine:)
            @cuts.sections(label, body) { |part, statements| routine_section(part, statements, routine: routine) }
          end

          # RET, which ends every routine section: a byte.
          RETURN_BYTES = 1

          # WHAT THE LOWERING HOLDS WHILE IT MAKES A ROUTINE (LoweringState), which RoutineCuts puts
          # back when a routine comes out too big for a bank. The Color measures a statement on the
          # lowering itself rather than on copies (#bytes_of), so this is used only for that.
          # Copied: the work memory, whose places a routine's own numbers take; and the lowering's
          # own lists and tables, so a place it noted in work memory goes back with the place.
          # Shared: the pictures, colours, sounds and clips it gathers (Art, Music, Clips), which a
          # measurement adds to and keeps as well, since adding the same picture twice changes nothing.
          # Left alone: the statements already cut into parts, and what the build worked out once.
          LOWERING_STATE = LoweringState.new(
            copied: [Memory],
            shared: [Integer, Symbol, String, NilClass, TrueClass, FalseClass, IR::Node, SceneHandover, LoweringPlan,
                     SM83, Art, Music, Clips, SquareColors, SpriteNames, Stacking::Picture, Set, RoutineCuts::PartCall],
            unchanged: %i[@cuts @cache]
          )

          # The console this lowers for (BuildCache).
          CONSOLE = Console::COLOR

          # WHAT THE COLOR'S LOWERING ALONE WORKS OUT FROM THE PROGRAM, once a build for all its tries
          # (BuildCache#facts): what each tile's picture gives (Art#tile_fact), the tiles each
          # background shows and its `set_tile`s put in it, the screens' modes, each tile's colours
          # with each of its background's lists, a background's lists at each step, its recolour
          # steps, and each sprite picture's pixels in each list. Each is a memo of the program
          # alone, filled as the lowering asks (Picture#recolor_steps_of and the rest).
          class BuildFacts
            attr_reader :tile_facts, :tiles_shown, :tile_colors_with, :recolor_steps, :recolor_steps_made, :list_swaps,
                        :sprite_pixels

            def initialize(cache)
              @cache = cache
              @tile_facts = {}
              @tiles_shown = {}
              @tile_colors_with = Hash.new { |all, swaps| all[swaps] = {} }.compare_by_identity
              @recolor_steps = {}
              @recolor_steps_made = {}
              @list_swaps = {}
              @sprite_pixels = {}
            end

            # The tiles each background's `set_tile`s put in its cells, by the background's name.
            def tiles_set_in
              @tiles_set_in ||= @cache.plan.reachable.select { |node| node.kind == :set_tile }.group_by(&:name)
                                      .transform_values { |nodes| nodes.flat_map(&:tiles_named) }
            end

            # How each screen of the program is shown (Modes.resolve).
            def screen_modes = @screen_modes ||= Modes.resolve(@cache.program)
          end

          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # --- statements ---

          def statement(node)
            return call_routine(node.label) if node.is_a?(RoutineCuts::PartCall)
            return statement_measured(node) if @measuring

            emit_statement(node)
          end

          # What a statement being measured has taken so far: where its code starts, and the numbers
          # and routine data it reads, each of which it would keep a copy of on its own.
          MeasuredStatement = Data.define(:from, :constants, :data)

          # A STATEMENT MADE WHILE A RUN OF THEM IS MEASURED (#bytes_of), its size noted for cutting
          # (RoutineCuts#note_size): the bytes it would come to measured on its own. That is its code,
          # which is the same wherever it stands, and the numbers and routine data it reads, which a
          # routine keeps once however many of its statements read them (#constant_label,
          # #routine_data_label) but which it would keep alone. So measuring a routine too big for a
          # bank once gives the size of every statement in it, at every depth, and cutting it
          # measures nothing again.
          def statement_measured(node)
            measured = MeasuredStatement.new(from: @asm.here, constants: Set.new, data: Set.new)
            @measured << measured
            emit_statement(node)
            @cuts.note_size(node, @asm.here - measured.from + measured.constants.sum { |value| Array(value).length * 4 } +
                                  measured.data.sum { |entries| entries.sum { |kind, _| ROUTINE_DATA_BYTES.fetch(kind) } })
          ensure
            @measured.pop
          end

          # The statements an `if`, a `loop` or a `repeat` holds, and an `if`'s `else`, as cut to fit
          # a bank (RoutineCuts#children_of). A game loop's are in the Color's order: the frame's
          # sprites and scroll placed before its wait (#emit_loop).
          def children_of(node) = @cuts.children_of(node)

          def console_loop(node) = @plan.console_loop(node)

          # Every game loop of the program.
          def game_loops = @plan.game_loops

          # Which shape each `repeat` can take (ControlFlow asks).
          def loop_form = @plan.loop_form

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # BCDE into the variable +name+. A variable a sprite is placed from marks the sprite changed
          # (Runtime::KeptSprites) — when the number is another than the one there, so a pose set
          # again every pass leaves the sprite as it is.
          def store(name)
            return store_kept_bytes(name) if kept_bytes(name)
            return emit_store_number(name) if sprites_placed_from(name).empty?

            # Compared a byte at a time, lowest first, and written from the first that differs: the
            # bytes below it are the same already.
            same = fresh("same_number")
            @asm.load(:hl, place_of(name))
            BCDE_LOW_FIRST.each_with_index do |register, i|
              @asm.load(:a, [:hl])
              @asm.cp_a(register)
              @asm.jump_relative(:nz, "#{same}_from#{i}")
              @asm.inc(:hl) unless i == 3
            end
            @asm.jump(same)
            BCDE_LOW_FIRST.each_with_index do |register, i|
              @asm.label("#{same}_from#{i}")
              @asm.load([:hl], register)
              @asm.inc(:hl) unless i == 3
            end
            emit_sprites_changed(name)
            @asm.label(same)
          end

          # The four bytes written where they are, lowest first: four bytes of code more than a
          # call to a routine that did it, and done in a little over half the time, which a
          # variable written many times a pass is worth.
          def emit_store_number(name)
            @asm.load(:hl, place_of(name))
            BCDE_LOW_FIRST.each_with_index do |register, i|
              next @asm.load([:hl], register) if i == 3

              @asm.load(:a, register)
              @asm.load([:hli], :a)
            end
          end

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var
            return emit_set_kept(node) if kept_bytes(node.var)

            value(node.value)
            store(node.var)
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`. For a number n written in the program the four bytes of x are
          # added to where they are, a dozen instructions and no call.
          def emit_sum(name, op, operand)
            amount = folded(operand)
            kept = kept_bytes(name)
            if amount
              add_in_place(place_of(name), op == :- ? Int32.neg(amount) : amount, kept || 4)
              emit_sprites_changed(name) unless amount.zero?
              return
            end
            if kept
              low_value(Build.binop(op, Build.var_ref(name), operand), kept)
              return store(name)
            end

            sum_of_two(Build.var_ref(name), operand, SUMS.fetch(op))
            store(name)
          end

          def add_in_place(address, amount, bytes = 4)
            amount &= 0xFFFF_FFFF
            @asm.load(:hl, address) if bytes > 1
            bytes.times do |i|
              byte = (amount >> (8 * i)) & 0xFF
              if bytes == 1
                @asm.load(:a, [address])
                @asm.add_a(byte)
                @asm.load([address], :a)
              else
                @asm.load(:a, [:hl])
                i.zero? ? @asm.add_a(byte) : @asm.adc_a(byte)
                @asm.load(i == bytes - 1 ? [:hl] : [:hli], :a)
              end
            end
          end

          def emit_copy(node)
            return if node.dest == node.src
            return emit_set_kept(Build.set(node.dest, Build.var_ref(node.src))) if kept_bytes(node.dest)

            value(node.src)
            store(node.dest)
          end

          def emit_negate(node)
            return emit_negate_kept(node.var) if kept_bytes(node.var)

            apply_to_variable(node.var, "rt_neg32")
          end

          def emit_abs(node) = apply_to_variable(node.var, "rt_abs32")

          def apply_to_variable(name, routine)
            value(name)
            @asm.call(routine)
            store(name)
          end

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def emit_negate_abs(node)
            done = fresh("not_above_nought")
            jump_unless(Build.binop(:>, Build.var_ref(node.var), Build.int(0)), done)
            apply_to_variable(node.var, "rt_neg32")
            @asm.label(done)
          end

          def emit_clamp(node)
            sum_of_three(node.var, node.min, node.max, "rt_clamp32")
            store(node.var)
          end

          # --- what ControlFlow asks of a lowering, in the SM83's instructions ---

          def fresh_label(what) = fresh(what)
          def place_label(label) = @asm.label(label)
          def jump(label) = @asm.jump(label)
          def emit_value(operand) = value(operand)
          def emit_store(name) = store(name)
          def emit_increment(name) = add_in_place(place_of(name), 1)
          def loop_statements(node) = children_of(node).first

          def emit_store_zero(name)
            load_constant(0)
            store(name)
          end

          def emit_copy_variable(from, to)
            value(from)
            store(to)
          end

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)

            call_routine(self.class.routine_label(node.target))
          end

          # Reference#exec_call_one_of: the number worked out once, and a number naming no routine of
          # the list — below nought or past its end — calls nothing. Compared as a number that cannot
          # be negative, -1 is the biggest there is, so one test guards both ends.
          def emit_call_one_of(node)
            which = keep_local(:which)
            value(node.which)
            store(which)
            none = fresh("calls_none")
            value(which)
            @asm.load(:hl, constant_label(node.targets.length))
            @asm.call("rt_cmpu32")
            @asm.cp_a(1) # below the list's length
            @asm.jump(:nz, none)
            table = if @indexes_in_banks
                      routine_data_label(node.targets.flat_map do |name|
                        [[:word, self.class.routine_label(name)], [:bank, self.class.routine_label(name)]]
                      end)
                    else
                      @routine_tables[node.targets] ||= "routines #{@routine_tables.length + 1}"
                    end
            value(which)
            @asm.load(:h, :d)
            @asm.load(:l, :e)
            @asm.add_hl(:hl)
            @asm.add_hl(:de) # × 3, an entry being an address and a bank
            @asm.load(:de, table)
            @asm.add_hl(:de)
            @asm.call("rt_far_call_hl")
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
              take_over(scene, number)
              jump_unless(Build.var_ref(at_power_on), done)
              call_routine(label)
              @asm.jump(done)
            else
              take_over(scene, number)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          # The scene numbered +number+ is the one running now, and what it does as it arrives is
          # done (Picture#emit_scene_arrival).
          def take_over(scene, number)
            load_constant(number)
            store(@scene)
            emit_scene_arrival(scene)
          end

          # A game that never waits for the screen has its bend worked out as it stops, for the
          # picture it stops on, as the interpreter works each row out as it paints it.
          # A pass that halts ends as every pass does, with its sprites and scroll placed
          # (IR::Frames::ConsoleLoop#pass_end): the running game loop's (#keep_loop_running), as
          # the interpreter ends it (Reference#place_pass_end_before_halt), and nothing before any runs.
          def emit_halt(_node)
            emit_bends(painting: true) unless @program.walk.any? { |node| node.kind == :wait_vblank }
            loops_ending_passes.each_with_index do |ending, i|
              other = fresh("not_this_loop")
              jump_unless(Build.binop(:==, Build.var_ref(@loop_running), Build.int(i + 1)), other)
              console_loop(ending).pass_end.each { |child| statement(child) }
              @asm.label(other)
            end
            @asm.call("rt_halt")
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them
          # (Reference#store_frame_counters): the frames shown by every frame the pass took, and what
          # the game catches up by held at the cap, both as the runtime counted them
          # (Runtime::Frame::FRAMES_TAKEN, STEP_TAKEN).
          #
          # The rows of each background bent row by row come first (Reference#work_out_bends): the
          # wait's blank sends the scroll this pass placed, and a row's bend goes out with it.
          def emit_wait_vblank(_node)
            @plan.bends_in_own_routine? ? call_routine(BENDS) : emit_bends
            @asm.call("rt_wait_vblank")
            emit_corners_forgotten
            emit_clock_each_pass
            @asm.load(:a, [@memory[Runtime::Frame::FRAMES_TAKEN]])
            @asm.load(:c, :a)
            @asm.load(:hl, place_of(Frames::COUNT))
            @asm.load(:a, [:hl])
            @asm.add_a(:c)
            @asm.load([:hli], :a)
            3.times do |i|
              @asm.load(:a, [:hl])
              @asm.adc_a(0)
              @asm.load(i == 2 ? [:hl] : [:hli], :a)
            end
            @asm.load(:hl, place_of(Frames::STEP))
            @asm.load(:a, [@memory[Runtime::Frame::STEP_TAKEN]])
            @asm.load([:hli], :a)
            @asm.xor_a(:a)
            3.times { @asm.load([:hli], :a) }
            value(Frames::COUNT)
            store(Frames::SEEN)
          end

          # --- lists (Runtime::Lists does the work and the checking) ---

          # Reference::ListValue.of: empty, or holding its capacity of the one number it is full of.
          def emit_list_new(node)
            return if held_run_on_list(node.name)
            return list_call("rt_list_empty", node) unless node.full_of

            list_call("rt_list_at_capacity", node)
            list_call("rt_list_fill", node, Build.int(0), Build.int(node.capacity), Build.int(node.full_of))
          end

          # A push onto a list of bytes or halves, with its value already in registers (Runtime::Lists
          # says why).
          def emit_list_push(node)
            place, _capacity, width = list_placed(node)
            push, = NARROW_LIST_ROUTINES[width]
            return list_call("rt_list_push", node, node.value) unless push

            value(node.value)
            @asm.load(:hl, place)
            @asm.call(push)
          end

          def emit_list_drop(node)
            return list_call("rt_list_drop", node, Build.int(0)) unless node.from == :front

            place, = list_placed(node)
            @asm.load(:hl, place + Runtime::Lists::LENGTH)
            @asm.call("rt_list_shift")
          end

          def emit_list_fill(node) = list_call("rt_list_fill", node, node.from, node.count, node.value)

          # A run of a table's entries copied into a list: the table's place and how it keeps its
          # entries, so the runtime reads them as a run does.
          def emit_list_copy(node)
            held = held_run_on_list(node.name)
            return emit_held_picture_copy(held, node) if held

            table = @tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
            kept, = TABLE_KEPT.fetch(table_keeping(table))
            list_call("rt_list_copy", node, Address.new(table_label(table.name)), Build.int(kept), Build.int(table.values.length),
                      node.at, Build.int(node.count))
          end

          # Where a sort keeps its numbers as it goes, in quick memory: the slot it is placing an item
          # from (2 bytes), the slot past the last (2), the item's number (4) and the item itself (4).
          LIST_SORT_NUMBERS = "the numbers a list sort keeps"

          # Reference#exec_list_sort: an insertion sort, written here with both lists' places known,
          # so nothing is looked up as it runs. Each item from the second on is taken out of its slot
          # with its number, and the items before it are moved up a slot while the one just before
          # has a number beyond its own, strictly; it then goes in the slot left. A list already in
          # order is one compare an item and no moves, and level numbers never pass each other.
          #
          # BC is the slot the item will go in, walking down; a compare is the item's number less
          # the one before's, a byte at a time from the lowest, and the borrow out of it shows which
          # is smaller as whole unsigned numbers. Two numbers of different signs are the other way
          # round as signed ones, so the borrow is turned over when their top bits differ.
          def emit_list_sort(node)
            refuse_sorting_front_dropped!(node)
            place, _capacity, width = list_placed(node)
            keys_place, _key_capacity, key_width = @lists.fetch(node.by) do
              raise LoweringError, "the list #{node.by.inspect} is sorted by and never declared"
            end
            numbers = @memory.reserve_quick(LIST_SORT_NUMBERS, 12)
            at, last, key, item = numbers, numbers + 2, numbers + 4, numbers + 8
            slots = place + Runtime::Lists::HEADER
            key_slots = keys_place + Runtime::Lists::HEADER
            sorted, next_item, take_item = fresh("sorted"), fresh("sort_next"), fresh("sort_item")
            compare, before, put_item = fresh("sort_compare"), fresh("sort_before"), fresh("sort_place")

            emit_sort_bounds(place, slots, width, at, last, sorted)
            @asm.label(next_item)
            @asm.load_high(:a, at)
            @asm.load(:c, :a)
            @asm.load_high(:a, at + 1)
            @asm.load(:b, :a)
            @asm.load_high(:a, last)
            @asm.cp_a(:c)
            @asm.jump_relative(:nz, take_item)
            @asm.load_high(:a, last + 1)
            @asm.cp_a(:b)
            @asm.jump(:z, sorted)
            @asm.label(take_item)
            @asm.load(:h, :b)
            @asm.load(:l, :c)
            width.times do |i|
              @asm.load(:a, [:hli])
              @asm.load_high(item + i, :a)
              @asm.load(:e, :a) if i.zero?
              @asm.load(:d, :a) if i == 1
            end
            @asm.load(:d, 0) if width == 1
            emit_sort_key_address(key_slots, key_width)
            key_width.times do |i|
              @asm.load(:a, [:hli])
              @asm.load_high(key + i, :a)
            end

            @asm.label(compare)
            @asm.load(:a, :c)
            @asm.cp_a(slots & 0xFF)
            @asm.jump_relative(:nz, before)
            @asm.load(:a, :b)
            @asm.cp_a(slots >> 8)
            @asm.jump(:z, put_item)
            @asm.label(before)
            @asm.load(:h, :b)
            @asm.load(:l, :c)
            width.times { @asm.dec(:hl) }
            @asm.load(:a, [:hli])
            @asm.load(:e, :a)
            width == 1 ? @asm.load(:d, 0) : @asm.load(:d, [:hl])
            emit_sort_key_address(key_slots, key_width)
            emit_sort_borrow(key, key_width, descending: node.descending)
            @asm.jump(:nc, put_item)
            emit_sort_move_up(width)
            @asm.jump(compare)

            @asm.label(put_item)
            width.times do |i|
              @asm.load_high(:a, item + i)
              @asm.load([:bc], :a)
              @asm.inc(:bc) unless i == width - 1
            end
            @asm.load_high(:a, at)
            @asm.add_a(width)
            @asm.load_high(at, :a)
            @asm.jump(:nc, next_item)
            @asm.load_high(:a, at + 1)
            @asm.inc(:a)
            @asm.load_high(at + 1, :a)
            @asm.jump(next_item)
            @asm.label(sorted)
          end

          # The slot past the last item into +last+ and the second slot into +at+, or straight to the
          # end, +sorted+, for a list of fewer than two items, which is in order already.
          def emit_sort_bounds(place, slots, width, at, last, sorted)
            @asm.load(:hl, place + Runtime::Lists::LENGTH)
            @asm.load(:a, [:hli])
            @asm.load(:h, [:hl])
            @asm.load(:l, :a)
            sorting = fresh("sort_some")
            @asm.load(:a, :h)
            @asm.or_a(:a)
            @asm.jump_relative(:nz, sorting)
            @asm.load(:a, :l)
            @asm.cp_a(2)
            @asm.jump(:c, sorted)
            @asm.label(sorting)
            (width / 2).times { @asm.add_hl(:hl) } # × the slot's width: 1, 2 or 4
            @asm.load(:de, slots)
            @asm.add_hl(:de)
            @asm.load(:a, :l)
            @asm.load_high(last, :a)
            @asm.load(:a, :h)
            @asm.load_high(last + 1, :a)
            second = slots + width
            @asm.load(:a, second & 0xFF)
            @asm.load_high(at, :a)
            @asm.load(:a, second >> 8)
            @asm.load_high(at + 1, :a)
          end

          # HL = where the number for the item in DE is, in the list of numbers whose slots start at
          # +key_slots+ and are +key_width+ bytes.
          def emit_sort_key_address(key_slots, key_width)
            @asm.load(:h, :d)
            @asm.load(:l, :e)
            (key_width / 2).times { @asm.add_hl(:hl) }
            @asm.load(:de, key_slots)
            @asm.add_hl(:de)
          end

          # The carry set when the item before (its number at HL) is to move up past the item placed,
          # whose number is at +key+: a number beyond the item's, strictly — bigger rising, smaller
          # with +descending+. The subtraction is the item's less the one before's, or the other way
          # round descending, and its borrow is turned over when the two top bits differ.
          def emit_sort_borrow(key, key_width, descending:)
            key_width.times do |i|
              if descending
                @asm.load_high(:a, key + i)
                @asm.load(:e, :a)
                @asm.load(:a, [:hl])
                i.zero? ? @asm.sub_a(:e) : @asm.sbc_a(:e)
              else
                @asm.load_high(:a, key + i)
                i.zero? ? @asm.sub_a([:hl]) : @asm.sbc_a([:hl])
              end
              @asm.inc(:hl) unless i == key_width - 1
            end
            @asm.sbc_a(:a) # every bit the borrow
            @asm.xor_a([:hl]) # ...turned over by the one before's top bit
            @asm.load(:e, :a)
            @asm.load_high(:a, key + key_width - 1)
            @asm.xor_a(:e) # ...and by the item's: its top bit gives the answer
            @asm.rla
          end

          # The item before BC moved up into BC's slot, top byte first, and BC a slot down.
          def emit_sort_move_up(width)
            @asm.load(:h, :b)
            @asm.load(:l, :c)
            @asm.dec(:hl)
            (width - 1).times { @asm.inc(:bc) }
            width.times do
              @asm.load(:a, [:hld])
              @asm.load([:bc], :a)
              @asm.dec(:bc)
            end
            (width - 1).times { @asm.dec(:bc) }
          end

          # A list something takes items from the front of keeps them round its slots like a ring, so
          # its items are not in a row from its first slot, which is what the sort walks.
          def refuse_sorting_front_dropped!(node)
            dropped = [node.name, node.by] & front_dropped_lists
            return if dropped.empty?

            raise NotMadeYet.new("The game puts a list in order (`list_sort`) and takes items from the front of " \
                                 "#{dropped.map(&:inspect).join(' and ')}. The Game Boy Color build does not make this yet. " \
                                 "To fix this, build the game for the Game Boy Advance only (`consoles: %i[gba]`).",
                                 part: "a list in order")
          end

          # Reference::ListValue#[]. The index is worked out first, and then it and the list's place
          # are written straight where rt_list_get reads them, in quick memory, rather than pushed
          # for it to copy off the stack: a pool's every field is a list, read several times a thing
          # a pass, and the copy was a large part of each read.
          #
          # A LIST NOTHING TAKES FROM THE FRONT keeps its first item in its first slot for good, so
          # an item's slot is its index: such a list's item is read straight from its place, once
          # the index is held to the length the header holds — every field of a pool is such a list.
          # An index out of range goes the whole way round, so the game stops as the interpreter's.
          def value_of_list_get(node)
            place, capacity, width = list_placed(node)
            if (slot = fixed_slot(node))
              @asm.load(:hl, slot)
              return @asm.call(TABLE_KEPT.fetch([width, true]).last)
            end
            if front_dropped_lists.include?(node.name)
              value(node.index)
              _push, item = NARROW_LIST_ROUTINES[width]
              return list_get_through_routine(place) unless item

              @asm.load(:hl, place + Runtime::Lists::LENGTH)
              return @asm.call(item)
            end

            out_of_range = fresh("list_index_out_of_range")
            done = fresh("list_item_read")
            emit_list_slot_of_index(node.index, place, capacity, width, out_of_range, fixed: fixed_length_lists.include?(node.name))
            @asm.call(TABLE_KEPT.fetch([width, true]).last) # a slot reads back with its top bit as the sign
            @asm.jump(done)
            @asm.label(out_of_range)
            value(node.index) if kept_list_index?(node.index, capacity)
            list_get_through_routine(place)
            @asm.label(done)
          end

          # Reference#exec_list_set, the same way for a list nothing takes from the front: the index
          # worked out and held to the length, then the value worked out and written into the slot,
          # as wide as the slot is. An index out of range goes through rt_list_set_taken, which stops the
          # game before anything is written.
          def emit_list_set(node)
            return list_call("rt_list_set", node, node.index, node.value) if front_dropped_lists.include?(node.name)

            place, capacity, width = list_placed(node)
            out_of_range = fresh("list_index_out_of_range")
            done = fresh("list_item_written")
            emit_list_slot_of_index(node.index, place, capacity, width, out_of_range, fixed: fixed_length_lists.include?(node.name))
            @asm.push(:hl)
            value(node.value)
            @asm.pop(:hl)
            %i[e d c b].first(width).each_with_index do |reg, i|
              @asm.inc(:hl) unless i.zero?
              @asm.load([:hl], reg)
            end
            @asm.jump(done)
            @asm.label(out_of_range)
            value(node.index) if kept_list_index?(node.index, capacity)
            list_set_through_routine(place)
            @asm.label(done)
          end

          # HL = the slot the index in BCDE names in the list at +place+, whose slots are +width+
          # bytes, a list whose first item is in its first slot; a jump to +out_of_range+, BCDE as
          # it was, for an index past 16 bits, below nought, or not below the length its header holds.
          def emit_list_slot_address(place, width, out_of_range, length: nil)
            @asm.load(:a, :b)
            @asm.or_a(:c)
            @asm.jump(:nz, out_of_range)
            emit_list_slot_of_de(place, width, out_of_range, length: length)
          end

          # The same for an index in DE alone. +length+ is the list's, for one that never changes
          # it (#fixed_length_lists), or nil to read it from the list's header.
          def emit_list_slot_of_de(place, width, out_of_range, length: nil)
            if length
              @asm.load(:a, :e)
              @asm.sub_a(length & 0xFF)
              @asm.load(:a, :d)
              @asm.sbc_a(length >> 8)
            else
              @asm.load(:hl, place + Runtime::Lists::LENGTH)
              @asm.load(:a, :e)
              @asm.sub_a([:hl])
              @asm.inc(:hl)
              @asm.load(:a, :d)
              @asm.sbc_a([:hl])
            end
            @asm.jump(:nc, out_of_range)
            @asm.load(:h, :d)
            @asm.load(:l, :e)
            (width / 2).times { @asm.add_hl(:hl) } # × the slot's width: 1, 2 or 4
            @asm.load(:de, place + Runtime::Lists::HEADER)
            @asm.add_hl(:de)
          end

          # The index in BCDE and the list at +place+ written where rt_list_set reads them, and the
          # write gone through with it, for an index out of range: the routine stops the game.
          def list_set_through_routine(place)
            emit_list_index_and_place(place, *Runtime::Lists.set_places(@memory))
            @asm.call("rt_list_set_taken")
          end

          # A LIST ALWAYS AS LONG AS IT CAN BE — declared full, and named by no step but a read, a
          # write or its length — has every slot in range for good, so a read at an index written in
          # the program is a read of one place in memory, with nothing to check: where the slot is,
          # or nil for any other read. A pool's copy of its things in order is such a list, read by
          # each of its sprites at a place of its own (DSL::Pool#stacked_list).
          def fixed_slot(node)
            index = folded(node.index)
            return nil unless index && fixed_length_lists.include?(node.name)

            place, capacity, width = list_placed(node)
            place + Runtime::Lists::HEADER + (index * width) if index.between?(0, capacity - 1)
          end

          # The names of the lists #fixed_slot reads straight from.
          def fixed_length_lists
            @fixed_length_lists ||= begin
              full = @program.walk.filter_map { |node| node.name if node.kind == :list_new && !node.full_of.nil? }
              others = @program.walk.reject { |node| FIXED_LENGTH_STEPS.include?(node.kind) }
              named = others.flat_map { |node| node.attrs.values.flat_map { |value| Array(value) } }.grep(Symbol)
              full - named
            end
          end

          # The steps that leave a list as long as it is.
          FIXED_LENGTH_STEPS = %i[list_new list_get list_set list_len].freeze

          # The lists some reachable step takes an item from the front of.
          def front_dropped_lists
            @front_dropped_lists ||= @reachable.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }.uniq
          end

          # The index in BCDE and the list at +place+ written where rt_list_get reads them, and read.
          def list_get_through_routine(place)
            emit_list_index_and_place(place, *Runtime::Lists.get_places(@memory))
            @asm.call("rt_list_get_taken")
          end

          # The index in BCDE at +index_at+ and the list's place at +list_at+, in quick memory.
          def emit_list_index_and_place(place, list_at, index_at)
            %i[e d c b].each_with_index do |reg, i|
              @asm.load(:a, reg)
              @asm.load_high(index_at + i, :a)
            end
            4.times do |i|
              @asm.load(:a, (place >> (8 * i)) & 0xFF)
              @asm.load_high(list_at + i, :a)
            end
          end

          # The length, read straight from the header: BCDE, its top half nought.
          def value_of_list_len(node)
            place, = list_placed(node)
            @asm.load(:hl, place + Runtime::Lists::LENGTH)
            @asm.load(:a, [:hli])
            @asm.load(:e, :a)
            @asm.load(:d, [:hl])
            @asm.load(:bc, 0)
          end

          # The runtime's list routine +routine+ on the list +node+ names, the list's place first.
          def list_call(routine, node, *args)
            place, = list_placed(node)
            runtime_call(routine, [Build.int(place), *args])
          end

          # The list +node+ names, as #sections placed it: [its place, its capacity, the bytes a slot,
          # its name].
          def list_placed(node)
            @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }
          end

          # Reference#exec_table_get: the index made safe (LoweringPlan.index_kept_in_range).
          def value_of_table_get(node)
            table = @tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            count = table.values.length
            bytes, signed = table_keeping(table)
            value(LoweringPlan.index_kept_in_range(node.index, count))
            reader = TABLE_KEPT.fetch([bytes, signed]).last
            return emit_far_entry_read(table, bytes, reader) if bytes * count > 0x10000

            # HL = the table + the index × the entry's size; the offset is never past 16 bits.
            (bytes / 2).times do
              @asm.sla(:e)
              @asm.rl(:d)
            end
            if banked_tables.include?(table.name)
              @asm.load(:hl, table_parts_label(table.name))
              @asm.load(:bc, reader)
              return @asm.call("rt_far_read_parts")
            end

            @asm.load(:hl, table_label(table.name))
            @asm.add_hl(:de)
            emit_entry_read(bytes, signed)
          end

          # A TABLE PAST 64 KILOBYTES, read at the index in BCDE, which is already held inside it.
          # The entry's offset (the index × the entry's size) is more than two bytes can hold, so it
          # is kept in three, CDE, and the part it is in is found here rather than by
          # rt_far_read_parts: the offset's bits from the part's size up are the part's number, and
          # its place in the list of parts (three bytes a part: its address and its bank) is that
          # number × 3. Such a table is always kept in banks, being far past BANKED_TABLE_BYTES.
          def emit_far_entry_read(table, bytes, reader)
            (bytes / 2).times do
              @asm.sla(:e)
              @asm.rl(:d)
              @asm.rl(:c)
            end
            in_part_bits = Runtime::Calls::TABLE_PART_BYTES.bit_length - 1 - 8 # the part's own bits of D
            # HL = the part's number: C's bits above those of D.
            @asm.load(:h, 0)
            @asm.load(:l, :c)
            (8 - in_part_bits).times { @asm.add_hl(:hl) }
            @asm.load(:a, :d)
            (8 - in_part_bits).times { @asm.rlca } # D's top bits brought round to the bottom
            @asm.and_a((1 << (8 - in_part_bits)) - 1)
            @asm.or_a(:l)
            @asm.load(:l, :a)
            # × 3, and the list's place added.
            @asm.load(:b, :h)
            @asm.load(:c, :l)
            @asm.add_hl(:hl)
            @asm.add_hl(:bc)
            @asm.load(:bc, table_parts_label(table.name))
            @asm.add_hl(:bc)
            @asm.load(:a, :d)
            @asm.and_a((1 << in_part_bits) - 1)
            @asm.load(:d, :a) # DE = the entry's place in its part
            @asm.load(:bc, reader)
            @asm.call("rt_far_read_part")
          end

          # BCDE = the entry at HL, +bytes+ wide, widened with its sign or without: what the
          # runtime's reader of that width does (Runtime::Calls#emit_table_readers), written where
          # the entry is read, since a call and its return take longer than the reading itself.
          def emit_entry_read(bytes, signed)
            return @asm.call("rt_read_int32") if bytes == 4

            if bytes == 2
              @asm.load(:a, [:hli])
              @asm.load(:e, :a)
              @asm.load(:a, [:hl])
              @asm.load(:d, :a)
            else
              @asm.load(:a, [:hl])
              @asm.load(:e, :a)
              @asm.load(:d, 0) unless signed
            end
            return @asm.load(:bc, 0) unless signed

            @asm.rla # the carry is the sign bit
            @asm.sbc_a(:a) # 0x00 or 0xFF
            @asm.load(:d, :a) if bytes == 1
            @asm.load(:c, :a)
            @asm.load(:b, :a)
          end

          # --- save memory (Runtime::Saving), laid out by IR::SaveLayout ---

          # Reference#exec_save_init: every `save_var` takes its saved number when save memory
          # carries the game's marker, and the number it was declared with when it does not. Each
          # is written back, and the marker after them, in that order, so a power cut lands on the
          # byte it lands on in the interpreter.
          def emit_save_init(node)
            saved = keep_local(:saved)
            marker_at = Build.int(SaveLayout::SAVE_VAR_MARKER_AT)
            marker = Int32.wrap(node.magic)
            value(Build.binop(:==, save_read(marker_at, :word), Build.int(marker)))
            store(saved)
            node.vars.each do |kept|
              at = Build.int(SaveLayout.save_var_at(kept.slot))
              declared = fresh("declared_number")
              chosen = fresh("number_chosen")
              jump_unless(Build.var_ref(saved), declared)
              value(save_read(at, :word))
              @asm.jump(chosen)
              @asm.label(declared)
              load_constant(Int32.wrap(kept.default))
              @asm.label(chosen)
              store(kept.name)
              runtime_call("rt_save_write", [at, kept.name, Build.int(SAVE_BYTES.fetch(:word))])
            end
            runtime_call("rt_save_write", [marker_at, Build.int(marker), Build.int(SAVE_BYTES.fetch(:word))])
            emit_clock_readings_from_save
          end

          # Reference#exec_save_store: one `save_var`'s number into its place.
          def emit_save_store(node)
            at = Build.int(SaveLayout.save_var_at(node.slot))
            runtime_call("rt_save_write", [at, node.var, Build.int(SAVE_BYTES.fetch(:word))])
          end

          # Reference#exec_save_write: the place worked out first and the value after it, as the
          # interpreter works them out, which is the order they are pushed in.
          def emit_save_write(node) = runtime_call("rt_save_write", [node.at, node.value, save_width(node)])

          # Reference#exec_save_erase: the wipe is waited for unless the node asks not to.
          def emit_save_erase(node) = runtime_call("rt_save_erase", [node.at, Build.int(node.wait == false ? 0 : 1)])

          # A whole list moved to or from save memory (Reference#exec_save_load_list,
          # #exec_save_store_list) as a block, by a routine of the runtime's (Runtime::Lists
          # #emit_save_moves). The count a load reads is held to nought and the step's most here,
          # and the most can be no more than the list holds, so the routine copies without looking.
          # The step's counter is left at nought, as every backend leaves it.
          def emit_save_list_move(node)
            if node.kind == :save_load_list
              _place, capacity, = list_placed(node)
              refusal = SaveListMoves.past_capacity_message(node, capacity)
              raise LoweringError, refusal if refusal

              list_call("rt_save_load_list", node, node.at, SaveListMoves.load_count(node))
            else
              list_call("rt_save_store_list", node, node.at)
            end
            emit_statement(Build.set(node.index, 0))
          end

          def value_of_save_read(node) = runtime_call("rt_save_read", [node.at, save_width(node)])
          def value_of_save_sum(node) = runtime_call("rt_save_sum", [node.at, node.length])

          def save_width(node) = Build.int(SAVE_BYTES.fetch(node.width))

          # A read of save memory, as a value for the statements above.
          def save_read(at, width) = Build.save_read(at, width: width)

          # --- timers ---
          #
          # A timer (`timer :beat, per_second: 10`) ticks so many times a second whatever the game is
          # doing, and runs what the game gave it to do on each tick. There is no clock in it: a frame is
          # the interpreter's sixtieth of a second, so at every frame boundary a running timer gains
          # its rate in sixtieths of a tick, and each whole tick that comes to is a tick
          # (Reference#accrue_timer). The Color's own hardware timer counts its own clock, which is
          # not the frame — a pass that runs late would tick it more than the interpreter ticks — so
          # this counts frames, as the interpreter does.
          #
          # Each timer keeps: when it was first started, as a count (nought for never), since timers
          # move on in the order they were first started, as the interpreter walks them; whether it is
          # running; its rate, as the whole ticks and the sixtieths of a tick a frame adds, kept apart
          # so that adding them never goes round at any rate a game can ask for; the sixtieths of a
          # tick it is through, always under sixty; and its whole ticks, coming round at 65536 as the
          # interpreter's count does. The runtime runs this lowering's routine at each frame boundary
          # (Runtime's rt_frame_begins), which moves every running timer on and runs its ticks.

          # The numbers each timer keeps (see above).
          TIMER_NUMBERS = %i[order running whole_rate part_rate parts ticks].freeze

          # A frame is a sixtieth of a second, as the interpreter counts one.
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
            add_in_place(place_of(@timers_started), 1)
            value(@timers_started)
            store(order)
            @asm.label(started)
            whole, part = node.hz.divmod(FRAMES_A_SECOND)
            { running: 1, whole_rate: whole, part_rate: part, parts: 0, ticks: 0 }.each do |what, number|
              load_constant(number)
              store(timer_number(node.name, what))
            end
          end

          # Reference#exec_timer_stop: its count is kept. A timer never started has nothing to stop.
          def emit_timer_stop(node)
            load_constant(0)
            store(timer_number(node.name, :running))
          end

          # Reference#timer_ticks: nought for a timer never started, which is what its count starts at.
          def value_of_timer_ticks(node) = value(timer_number(node.name, :ticks))

          # THE ROUTINES THE RUNTIME RUNS AT EACH FRAME BOUNDARY: one that moves every running timer
          # on, in the order the timers were first started — the k-th started is looked for k-th —
          # and one for each timer, which moves it on and runs its handler, so each handler is made
          # once however many timers there are. None for a game with no timers.
          def timer_sections
            return [] if @timers.empty?

            each_timer = @timers.flat_map { |name, number| timer_section(name, number) }
            @frame_begins = "timers frame"
            in_order = routine_section(@frame_begins, [], routine: "the timers") do
              with_call_numbers_kept do
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

          # The routine every wait calls to work out the bends' rows, in a game whose bends are one
          # (LoweringPlan#bends_in_own_routine?).
          BENDS = "bends frame"

          # That routine, with the numbers of a call its steps can come inside put back around them
          # (#with_call_numbers_kept), which are known only once every routine of the game is made.
          def bend_sections
            return [] unless @plan.bends_in_own_routine?

            [routine_section(BENDS, [], routine: "the bends") { with_call_numbers_kept { emit_bends } }]
          end

          # One timer, a frame on: its sixtieths, the whole ticks they come to, and its handler run
          # once for each. How many that is is settled before the first of them runs, so a handler
          # that stops or restarts its own timer still finishes the ticks this frame crossed, as the
          # interpreter's does. A handler too big for a bank is cut into parts as a routine is
          # (RoutineCuts).
          def timer_section(name, _number)
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
                add_in_place(place_of(@timer_crossed), -1)
                @asm.jump(top)
                @asm.label(done)
              end
            end
            [each_tick, *@cuts.part_sections(cut) { |part, statements| routine_section(part, statements, routine: routine) }]
          end

          # --- tests: jump unless one holds ---

          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.jump(label) if known

            if (equal = equality_of_kept(condition))
              compare_kept_with_number(*equal)
              return @asm.jump(condition.op == :== ? :z : :nz, label)
            end
            return jump_unless(condition.lhs, label) if turned_round?(condition)

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            @asm.jump(label)
            @asm.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on rt_cmp32's answer straight
          # away, without making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.jump(label) if known.zero?) if known

            if turned_round?(condition)
              jump_if(condition.lhs, label)
            elsif (equal = equality_with_number(condition))
              compare_with_number(*equal)
              @asm.jump(condition.op == :== ? :nz : :z, label)
            elsif (equal = equality_of_kept(condition))
              compare_kept_with_number(*equal)
              @asm.jump(condition.op == :== ? :nz : :z, label)
            elsif (equal = equality_of_two_kept(condition))
              compare_two_kept(*equal)
              @asm.jump(condition.op == :== ? :nz : :z, label)
            elsif (equal = equality_of_byte_item(condition))
              compare_byte_item_with_number(*equal)
              @asm.jump(condition.op == :== ? :nz : :z, label)
            elsif (name = sign_tested_variable(condition))
              # A variable at or above nought, or below it, is its top bit, where it is kept.
              @asm.load(:a, [place_of(name) + (kept_bytes(name) || 4) - 1])
              @asm.bit(7, :a)
              @asm.jump(condition.op == :>= ? :nz : :z, label)
            elsif (ordered = ordering_of_two_kept(condition))
              emit_carry_when_kept_below_kept(*ordered.first(2))
              @asm.jump(ordered.last ? :nc : :c, label)
            elsif (ordered = ordering_with_number(condition))
              other, number, below = ordered
              if number
                jump_unless_below(other, number, below, label)
              elsif !below
                @asm.jump(label)
              end
            elsif (ordered = ordering_with_variable(condition))
              other, name, below = ordered
              emit_carry_when_below_variable(other, name)
              @asm.jump(below ? :nc : :c, label)
            elsif binop?(condition, :and) && right_side_skippable?(condition)
              # The interpreter works both sides out; the second is skipped here when the first has
              # decided, which is the same thing where working it out changes nothing.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif binop?(condition, :or) && right_side_skippable?(condition)
              holds = fresh("either_holds")
              jump_if(condition.lhs, holds)
              jump_unless(condition.rhs, label)
              @asm.label(holds)
            elsif condition.is_a?(Node) && condition.kind == :binop && COMPARISONS.key?(condition.op)
              compare(condition)
              _, holds_when = COMPARISONS.fetch(condition.op)
              @asm.jump(holds_when == :z ? :nz : :z, label)
            else
              value(condition)
              @asm.call("rt_test32")
              @asm.jump(:z, label)
            end
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          def right_side_skippable?(join) = Unchanging.value?(join.rhs) { |part| folded(part) }

          # `test == 0` is how `!`, `unless` and `while` turn a test round: a comparison or a join
          # asked the other way, with no 0 or 1 made of it first.
          def turned_round?(condition)
            return false unless binop?(condition, :==) && folded(condition.rhs)&.zero?

            test = condition.lhs
            test.is_a?(Node) && test.kind == :binop && (COMPARISONS.key?(test.op) || %i[and or].include?(test.op))
          end

          # The variable +condition+ asks is at or above nought (>= 0), or below it (< 0), or nil.
          def sign_tested_variable(condition)
            return nil unless (binop?(condition, :>=) || binop?(condition, :<)) && folded(condition.rhs)&.zero?

            variable_named(condition.lhs) || kept_variable_named(condition.lhs)
          end

          # A variable tested to equal (or not) a number written in the program: [its place, the
          # number], or nil for any other test.
          def equality_with_number(condition)
            return nil unless binop?(condition, :==) || binop?(condition, :!=)

            left, right = condition.lhs, condition.rhs
            left, right = right, left if folded(left)
            number = folded(right)
            name = variable_named(left)
            return nil unless number && name

            [place_of(name), number & 0xFFFF_FFFF]
          end

          # An item of a list of bytes tested to equal (or not) a number a byte holds: [the read, the
          # number], or nil for any other test. A pool asks this of every thing it walks (is the slot
          # live?), and the item is a byte in memory: one compare, with no whole number made of it.
          def equality_of_byte_item(condition)
            return nil unless binop?(condition, :==) || binop?(condition, :!=)

            left, right = condition.lhs, condition.rhs
            left, right = right, left if folded(left)
            number = folded(right)
            return nil unless number&.between?(-0x80, 0x7F) && left.is_a?(Node) && left.kind == :list_get
            return nil if front_dropped_lists.include?(left.name)

            [left, number] if list_placed(left)[2] == 1
          end

          # The zero flag set when the item +item+ reads is +number+. An index out of range stops the
          # game, as reading the item would.
          def compare_byte_item_with_number(item, number)
            if (slot = fixed_slot(item))
              @asm.load(:a, [slot])
            else
              place, capacity, width = list_placed(item)
              out_of_range = fresh("list_index_out_of_range")
              read = fresh("list_item_read")
              emit_list_slot_of_index(item.index, place, capacity, width, out_of_range, fixed: fixed_length_lists.include?(item.name))
              @asm.load(:a, [:hl])
              @asm.jump(read)
              @asm.label(out_of_range)
              value(item.index) if kept_list_index?(item.index, capacity)
              list_get_through_routine(place)
              @asm.label(read)
            end
            @asm.cp_a(number & 0xFF)
          end

          # The whole-number variable +node+ names, read where it is kept. One kept narrow is not one:
          # everything asking here reads four bytes, and falls back on working the value out.
          def variable_named(node)
            name = any_variable_named(node)
            name unless name && kept_bytes(name)
          end

          def any_variable_named(node)
            return node if node.is_a?(Symbol)

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # The zero flag set when the four bytes at +address+ are +number+, byte by byte, leaving at
          # the first that differs.
          def compare_with_number(address, number)
            done = fresh("compared")
            @asm.load(:hl, address)
            4.times do |i|
              @asm.load(:a, i == 3 ? [:hl] : [:hli])
              @asm.cp_a((number >> (8 * i)) & 0xFF)
              @asm.jump_relative(:nz, done) unless i == 3
            end
            @asm.label(done)
          end

          # rt_cmp32 on the two sides of a comparison, and A compared with what the comparison holds
          # on, so the zero flag gives the answer.
          def compare(node)
            byte = folded(node.rhs)
            if byte&.between?(0, 0xFF)
              emit_compare_with_byte(node.lhs, byte)
            else
              with_hl_at(node.rhs) do |where|
                value(node.lhs)
                point_hl(where)
                @asm.call("rt_cmp32")
              end
            end
            k, = COMPARISONS.fetch(node.op)
            k.zero? ? @asm.and_a(:a) : @asm.cp_a(k)
          end

          # A as rt_cmp32 leaves it, for +left+ against +byte+, a number from 0 to 255 written in the
          # program: a number below nought is less, one past a byte greater, and one of a byte is
          # compared with it where it is — a handful of instructions rather than a call.
          def emit_compare_with_byte(left, byte)
            less = fresh("less")
            greater = fresh("greater")
            equal = fresh("equal")
            done = fresh("compared")
            name = variable_named(left)
            if name
              # A variable is asked where it is, its top byte first: its sign, then whether its upper
              # bytes are nought, then its lowest against the byte.
              @asm.load(:hl, place_of(name) + 3)
              @asm.load(:a, [:hld])
              @asm.bit(7, :a)
              @asm.jump_relative(:nz, less)
              @asm.or_a([:hl])
              @asm.dec(:hl)
              @asm.or_a([:hl])
              @asm.dec(:hl)
              @asm.jump_relative(:nz, greater)
              @asm.load(:a, [:hl])
            else
              value(left)
              @asm.bit(7, :b)
              @asm.jump_relative(:nz, less)
              emit_upper_bytes_or
              @asm.jump_relative(:nz, greater)
              @asm.load(:a, :e)
            end
            @asm.cp_a(byte)
            @asm.jump_relative(:c, less)
            @asm.jump_relative(:z, equal)
            @asm.label(greater)
            @asm.load(:a, 2)
            @asm.jump_relative(done)
            @asm.label(less)
            @asm.load(:a, 1)
            @asm.jump_relative(done)
            @asm.label(equal)
            @asm.xor_a(:a)
            @asm.label(done)
          end

          # A = B | C | D, the three upper bytes of the number in BCDE, so the zero flag shows
          # whether the number is one byte, from 0 to 255.
          def emit_upper_bytes_or
            @asm.load(:a, :b)
            @asm.or_a(:c)
            @asm.or_a(:d)
          end

          # --- values: each leaves its number in BCDE ---

          def value(operand)
            known = folded(operand)
            return load_constant(known) if known

            case operand
            when Symbol then load_variable(operand)
            when Node then value_of_kind(operand)
            when Address then load_label(operand.label)
            when BankedAddress then load_banked_label(operand.label)
            when Entry then table_entry(operand)
            when RuntimeValue then runtime_call(operand.routine, operand.args)
            when Sum then value_of_binop(operand)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def load_label(label)
            @asm.load(:bc, 0)
            @asm.load(:de, label)
          end

          def load_banked_label(label)
            @asm.load(:b, 0)
            @asm.load_bank_of(:c, label)
            @asm.load(:de, label)
          end

          # The entry of a table of the drawing's numbers at an index the program has already kept
          # inside it: HL = the table + the index × the entry's size.
          def table_entry(entry)
            value(entry.index)
            (entry.bytes / 2).times do
              @asm.sla(:e)
              @asm.rl(:d)
            end
            @asm.load(:hl, entry.label)
            @asm.add_hl(:de)
            reader = TABLE_KEPT.fetch([entry.bytes, entry.signed]).last
            return @asm.call(reader) unless entry.banked

            @asm.load_bank_of(:a, entry.label)
            @asm.load(:de, reader)
            @asm.call("rt_far_read")
          end

          def value_of_int(node) = load_constant(node.value)

          # The Color has one controller, so one player is connected, always.
          def value_of_players_connected(_node) = load_constant(1)

          # A cartridge is played by one person, the first player.
          def value_of_local_player(_node) = load_constant(1)
          def value_of_var_ref(node) = load_variable(node.name)

          def value_of_binop(node)
            if COMPARISONS.key?(node.op)
              if (ordered = ordering_with_number(node))
                other, number, below = ordered
                return number ? emit_bool_of_below(other, number, below) : load_constant(below ? 1 : 0)
              end
              if (ordered = ordering_with_variable(node))
                other, name, below = ordered
                emit_carry_when_below_variable(other, name)
                return emit_bool_of_carry(below)
              end

              compare(node)
              _, holds_when = COMPARISONS.fetch(node.op)
              return @asm.call(holds_when == :z ? "rt_bool_of_z" : "rt_bool_of_nz")
            end
            return if node.op == :* && (emit_product_by_power_of_two(node) || emit_product_by_byte(node) ||
                                        emit_product_by_byte_value(node))
            return if %i[+ -].include?(node.op) && emit_sum_with_constant(node)
            return if node.op == :& && emit_and_with_byte(node)
            return if %i[& | ^].include?(node.op) && emit_bitwise_with_written_number(node)
            return if %i[<< >>].include?(node.op) && emit_shift_by_written_count(node)
            return if node.op == :/ && emit_divide_by_number(node)
            return if node.op == :% && emit_remainder_by_number(node)

            sum_of_two(node.lhs, node.rhs, SUMS.fetch(node.op))
          end

          # A number AND a byte written in the program — a table's index kept inside the table — is
          # its lowest byte AND that one, and nought above: the byte read where a variable is kept,
          # in a few instructions rather than all four through a call. True when it was done so.
          def emit_and_with_byte(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              mask = folded(by)
              next unless mask&.between?(0, 0xFF)

              name = variable_named(other)
              if name
                @asm.load(:a, [place_of(name)])
              else
                value(other)
                @asm.load(:a, :e)
              end
              @asm.and_a(mask)
              @asm.load(:e, :a)
              @asm.load(:d, 0)
              @asm.load(:bc, 0)
              return true
            end
            false
          end

          # A number plus or minus one written in the program — a pose picked by a number, plus
          # where its row starts; a piece's column, less how far left of the sprite it sits — added
          # in BCDE where it is, a byte of the number written to each byte, the carry walked up: a
          # dozen instructions rather than a call, and none at all for nought. True when it was
          # done so.
          def emit_sum_with_constant(node)
            sides = node.op == :+ ? [[node.rhs, node.lhs], [node.lhs, node.rhs]] : [[node.rhs, node.lhs]]
            sides.each do |by, other|
              number = folded(by)
              next unless number

              value(other)
              number = Int32.neg(number) if node.op == :-
              return true if number.zero?

              BCDE_LOW_FIRST.each_with_index do |register, i|
                byte = (number >> (8 * i)) & 0xFF
                @asm.load(:a, register)
                i.zero? ? @asm.add_a(byte) : @asm.adc_a(byte)
                @asm.load(register, :a)
              end
              return true
            end
            false
          end

          def value_of_neg(node) = sum_of_one(node.operand, "rt_neg32")
          def value_of_bit_not(node) = sum_of_one(node.operand, "rt_not32")
          def value_of_absolute(node) = sum_of_one(node.operand, "rt_abs32")
          # A number held between two ends written in the program, which a table read by a number the
          # game works out always is (LoweringPlan.index_kept_in_range): almost always it is already
          # between them, so that is asked first, of the bytes where it is — a handful of
          # instructions, on the one byte that can hold it when both ends are a byte, on the low two
          # when they are two (a table longer than 256 entries) — and only a number outside them is
          # held, by rt_clamp16_outside, which knows it is outside and so needs no 32-bit compare,
          # with the ends kept beside each other as the routine reads them. Ends that are not
          # written in the program, or not from nought to two bytes, go to rt_clamp32.
          def value_of_clamped(node)
            low, high = folded(node.min), folded(node.max)
            return sum_of_three(node.operand, node.min, node.max, "rt_clamp32") unless range_within?(low, high, 0xFFFF)

            held = fresh("held")
            within = fresh("within")
            value(node.operand)
            if range_within?(low, high, 0xFF)
              emit_byte_within(low, high, held, within)
            else
              emit_half_within(low, high, held, within)
            end
            @asm.label(held)
            @asm.load(:hl, constant_label([low, high]))
            @asm.call("rt_clamp16_outside")
            @clamps_outside = true
            @asm.label(within)
          end

          # Off to +within+ when BCDE is a byte from +low+ to +high+, both a byte; on to +held+
          # otherwise.
          def emit_byte_within(low, high, held, within)
            emit_upper_bytes_or
            @asm.jump_relative(:nz, held)
            @asm.load(:a, :e)
            unless low.zero?
              @asm.cp_a(low)
              @asm.jump_relative(:c, held)
            end
            if high == 0xFF
              @asm.jump_relative(within)
            else
              @asm.cp_a(high + 1)
              @asm.jump_relative(:c, within)
            end
          end

          # Off to +within+ when BCDE is from +low+ to +high+, both two bytes: its top two bytes
          # nought, and DE compared with each end by a subtraction whose borrow says which side.
          def emit_half_within(low, high, held, within)
            @asm.load(:a, :b)
            @asm.or_a(:c)
            @asm.jump_relative(:nz, held)
            unless low.zero?
              emit_de_minus(low)
              @asm.jump_relative(:c, held)
            end
            return @asm.jump_relative(within) if high == 0xFFFF

            emit_de_minus(high + 1)
            @asm.jump_relative(:c, within)
          end

          # The borrow of DE less +number+, two bytes, into the carry; DE is left as it was.
          def emit_de_minus(number)
            @asm.load(:a, :e)
            @asm.sub_a(number & 0xFF)
            @asm.load(:a, :d)
            @asm.sbc_a(number >> 8)
          end

          # Two ends written in the program, each from nought to +most+, the floor at or below the
          # ceiling.
          def range_within?(low, high, most) = low && high && low.between?(0, most) && high.between?(low, most)
          def value_of_mul_fix(node) = sum_of_three(node.lhs, node.rhs, fraction_bits(node), "rt_mul_fix")
          def value_of_div_fix(node) = sum_of_three(node.lhs, node.rhs, fraction_bits(node), "rt_div_fix")
          def value_of_shift_right(node)
            value(node.operand)
            emit_shift_in_place(:>>, node.bits)
          end
          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # One byte of a named piece of data. The index is a number written in the program, so one
          # past the end is refused here, where the interpreter would refuse it as it runs.
          def value_of_data_byte(node)
            data = @pictures.fetch(node.name) { raise LoweringError, "reference to undefined data #{node.name.inspect}" }
            bytes = (data.kind == :data ? data.bytes : data.pixels).bytes
            unless node.index.between?(0, bytes.length - 1)
              raise LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}"
            end

            value(Entry.new(drawing_table("data #{node.name}", 1, bytes), 1, false, Build.int(node.index)))
          end

          def value_of_held(node) = runtime_call("rt_held", [Build.int(button_number(node.button))])
          def value_of_pressed(node) = runtime_call("rt_pressed", [Build.int(button_number(node.button))])

          # How many bits of a number hold its fraction: the runtime's sums are written for 0 to 32,
          # every scale the framework uses.
          def fraction_bits(node)
            bits = node.fraction_bits
            unless bits.between?(0, 32)
              raise LoweringError, "a number with #{bits} bits of fraction is more than the Game Boy Color build can " \
                                   "work out. It can work out 0 to 32."
            end

            Build.int(bits)
          end

          # The buttons in the order the console's key register holds them (IR::Buttons::NAMES); -1
          # means any of them.
          def button_number(button)
            return -1 if button == Buttons::ANY

            Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}"
          end

          # The four bytes read where they are, as #emit_store_number writes them.
          def load_variable(name)
            return load_kept_variable(name) if kept_bytes(name)

            @asm.load(:hl, place_of(name))
            BCDE_LOW_FIRST.each_with_index do |register, i|
              next @asm.load(register, [:hl]) if i == 3

              @asm.load(:a, [:hli])
              @asm.load(register, :a)
            end
          end

          def load_constant(number)
            number &= 0xFFFF_FFFF
            @asm.load(:bc, number >> 16)
            @asm.load(:de, number & 0xFFFF)
          end

          # A place in the routine's data holding +number+, or a pair of them side by side, kept once
          # beside it, and the label of where.
          def constant_label(number)
            key = number.is_a?(Array) ? number.map { |part| part & 0xFFFF_FFFF } : number & 0xFFFF_FFFF
            @measured.each { |measured| measured.constants << key } if @measuring
            @constants[key] ||= fresh("number")
          end

          def folded(node) = @plan.folded(node)

          # A product by a power of two up to 16 written in the program, as shifts of the four bytes
          # a place at a time rather than the runtime's multiply — none at all for a product by one.
          # True when it was done so.
          def emit_product_by_power_of_two(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              number = folded(by)
              next unless number&.positive? && (number & (number - 1)).zero? && number <= 16

              value(other)
              number.bit_length.pred.times do
                @asm.sla(:e)
                @asm.rl(:d)
                @asm.rl(:c)
                @asm.rl(:b)
              end
              return true
            end
            false
          end

          # A number times a byte written in the program — a row of a sprite's poses times how many
          # poses it has — by rt_mul32_byte, which walks the byte's bits in A rather than the 32 of
          # a number at HL (Runtime::Int32). True when it was done so.
          def emit_product_by_byte(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              number = folded(by)
              next unless number&.between?(1, 0xFF)

              value(other)
              @asm.load(:a, number)
              @asm.call("rt_mul32_byte")
              return true
            end
            false
          end

          def sum_of_one(operand, routine)
            value(operand)
            @asm.call(routine)
          end

          # The left number in BCDE and the right one at HL, for the runtime's +routine+.
          def sum_of_two(left, right, routine)
            with_hl_at(right) do |where|
              value(left)
              point_hl(where)
              @asm.call(routine)
            end
          end

          # The first number in BCDE, the second at HL and the third just past it: both pushed.
          def sum_of_three(first, second, third, routine)
            [third, second].each { |node| push_value(node) }
            value(first)
            @asm.load_hl_sp(0)
            @asm.call(routine)
            @asm.add_sp(8)
          end

          # Run the block with the number +node+ somewhere HL can be pointed at, handing it where (for
          # #point_hl): a variable or a number the routine keeps is pointed at where it is, and
          # anything else is worked out first and pushed, and taken off again after.
          def with_hl_at(node)
            known = folded(node)
            name = variable_named(node)
            where = if known then [:label, constant_label(known)]
                    elsif name then [:address, place_of(name)]
                    end
            return yield(where) if where

            push_value(node)
            yield [:stack]
            @asm.add_sp(4)
          end

          # The number +node+ worked out into BCDE and pushed, four bytes, high half first: the stack
          # then holds it as a number is kept anywhere else, lowest byte first.
          def push_value(node)
            value(node)
            @asm.push(:bc)
            @asm.push(:de)
          end

          def point_hl((kind, at)) = kind == :stack ? @asm.load_hl_sp(0) : @asm.load(:hl, at)

          # A runtime routine taking +args+, each pushed in order, the first deepest: the routine finds
          # the last of them just past its return address.
          def runtime_call(name, args)
            args.each { |arg| push_value(arg) }
            @asm.call(name)
            bytes = args.length * 4
            while bytes.positive?
              step = [bytes, 124].min
              @asm.add_sp(step)
              bytes -= step
            end
          end

          # A routine of the game's: a plain CALL where the linker places it in this routine's bank,
          # else through bank 0, which puts its bank in view (SM83#call_banked).
          def call_routine(label) = @asm.call_banked(label)
        end
      end
    end
  end
end
