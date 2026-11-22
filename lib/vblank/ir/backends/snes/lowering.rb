# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # One program, lowered straight to 65816 machine code: the Super Nintendo's peer of the GBA
        # and Game Boy Color lowerings. It walks the IR with a table naming the method for each kind
        # of statement and each kind of value (the interpreter's own shape, Reference), and emits the
        # instructions through the assembler (W65816), calling the runtime (SNES::Runtime) for what
        # is too long to write in place.
        #
        # How a number is worked out. Every value leaves its answer in R0, the first working number on
        # the direct page (Memory.register), its low half first. A sum of two works the left-hand side
        # out into R0 and takes the right-hand side from where it already is — a number written in
        # the program is part of the instruction, a variable is read where it lives — so `x + 1` is
        # six instructions and no call. A right-hand side that has to be worked out first is worked
        # out, pushed on the stack, and pulled into R1 once the left-hand side is in R0. A runtime
        # routine taking several numbers has them in R0, R1, R2... Nothing is kept in a register from
        # one statement to the next, so a statement never has to know what came before it. A and the
        # index registers are 16 bits wide throughout.
        #
        # Where things live. The game's variables, and each routine's own numbers — a loop's count, a
        # `case`'s reading — are places in the first 8K of work RAM (Memory), fixed while the program
        # is built, so a routine cannot call itself, and a program in which one can is refused. Lists
        # are in the rest of work RAM. Every routine is called with JSL and returns with RTL, so it can
        # be in any bank of the cartridge.
        #
        # It makes the kinds in its two tables, and refuses by name a program that reaches one it does
        # not make yet (NOT_LOWERED_YET), and one a Super Nintendo cannot do at all in the words its
        # answers have (Console::Answers#refusals).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the
          # +part+ of the build that is missing ("the picture"), for a test run to count skips by.
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          include ControlFlow
          include BendSchedule
          include ListPackBlocks
          include DrawOrderWalk
          include SceneryWrites
          include MeasuredOnCopies

          # Every kind this lowering writes: its own, each by a method called by name in
          # #emit_statement and #value_of_kind, and each part's (Picture, Paint and the rest, and the
          # loops and tests every cartridge lowering shares, ControlFlow), which each part writes in a
          # case of its own. A declaration writes nothing where it is. Read by
          # test_snes_kind_coverage.rb.
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp call call_one_of
            halt wait_vblank list_new list_push list_drop list_set list_fill list_copy list_sort list_pack
            timer_start timer_stop on_timer show_light_now rumble show_held_tiles
          ] + ControlFlow::STATEMENT_KINDS + Picture::STATEMENT_KINDS + Paint::STATEMENT_KINDS + Saving::STATEMENT_KINDS +
            Sound::STATEMENT_KINDS + Nodes.of_role(:declaration)).freeze

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
            when :repeat
              with_invariant_reads_kept(node) { stepped_walk?(node) ? emit_stepped_walk(node) : emit_control_flow_statement(node) }
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
            when :list_pack then emit_list_pack(node)
            when :timer_start then emit_timer_start(node)
            when :timer_stop then emit_timer_stop(node)
            # a timer's handler runs as its timer ticks, not where it is written
            when :on_timer then emit_nothing(node)
            # no light can be made on a Super Nintendo (its answers refuse one), and a game without
            # one works nothing out again
            when :show_light_now then emit_nothing(node)
            # a Super Nintendo cartridge has no rumble motor, so nothing is felt
            # (Console::Description#rumbles)
            when :rumble then emit_nothing(node)
            # video memory is written only between frames here, so a held background's changes
            # already show together
            when :show_held_tiles then emit_nothing(node)
            when *Picture::STATEMENT_KINDS then emit_picture_statement(node)
            when *Paint::STATEMENT_KINDS then emit_paint_statement(node)
            when *Saving::STATEMENT_KINDS then emit_saving_statement(node)
            when *Sound::STATEMENT_KINDS then emit_sound_statement(node)
            else emit_declaration_or_refuse(node)
            end
          end

          # A declaration is gathered before the program is written, so it writes nothing where it
          # is; any other kind with no writer is a mistake in this file.
          def emit_declaration_or_refuse(node)
            return emit_nothing(node) if Nodes.of_role(:declaration).include?(node.kind)

            raise LoweringError, "no writer here for #{node.kind.inspect}"
          end

          include Picture
          include Paint
          include Collision
          include Saving
          include Sound
          include Chip
          include ShownSort

          VALUE_KINDS = (%i[
            int var_ref binop neg bit_not absolute clamped mul_fix div_fix shift_right held pressed pulled list_get
            list_len table_get timer_ticks chance local_player players_connected
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
            when :mul_fix then value_of_mul_fix(node)
            when :div_fix then value_of_div_fix(node)
            when :shift_right then value_of_shift_right(node)
            when :held then value_of_held(node)
            when :pressed then value_of_pressed(node)
            when :pulled then value(Build.pulled_as_held(node))
            when :list_get then value_of_list_get(node)
            when :list_len then value_of_list_len(node)
            when :table_get then value_of_table_get(node)
            when :timer_ticks then value_of_timer_ticks(node)
            when :chance then value_of_chance(node)
            when :local_player then value_of_local_player(node)
            when :players_connected then value_of_players_connected(node)
            when *Collision::VALUE_KINDS then value_of_collision_kind(node)
            when *Saving::VALUE_KINDS then value_of_saving_kind(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # Every kind this lowering cannot make yet, by what it is part of. A kind leaves the list the
          # day the Super Nintendo does it; test_snes_kind_coverage.rb holds the list and the tables
          # above to every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({
                                                    "the picture" => %i[show_picture_group data_byte],
                                                    "sprite tiles the game loads" => %i[load_sprite_tiles]
                                                  })

          # How the runtime's list copy knows each way of keeping an entry (Runtime::Lists::KEPT), by
          # its bytes and its sign (LoweringPlan#table_keeping).
          TABLE_KEPT = Ractor.make_shareable({ [1, true] => :signed_byte, [1, false] => :byte, [2, true] => :signed_half,
                                               [2, false] => :half, [4, true] => :word })

          # The bytes a part of a table bigger than a bank holds of its own entries (#table_sections):
          # half a bank, so a part and the entries it holds of the next together still fit in one.
          PART_BYTES = 0x4000

          # The runtime's routines for a binop worked out by a call, and the binops written in place.
          CALLED_SUMS = Ractor.make_shareable({ :* => "rt_mul32", :/ => "rt_div32", :% => "rt_mod32",
                                                :<< => "rt_shl32", :>> => "rt_shr32" })
          IN_PLACE_OPS = %i[+ - & | ^].freeze
          COMPARISONS = %i[< <= > >= == !=].freeze
          BITWISE = %i[& | ^].freeze

          # What a half of a bitwise sum comes to when the other side's half is a number written in
          # the program: the other half as it was, or that number itself whatever the other half is.
          # Any other number is worked out (#emit_bitwise_halves).
          HALF_KEPT = Ractor.make_shareable({ :& => 0xFFFF, :| => 0, :^ => 0 })
          HALF_WRITTEN = Ractor.make_shareable({ :& => 0, :| => 0xFFFF })

          # What the game's code is to the author, for a cartridge too full for it (Linker::TooBig).
          DATA = W65816::Holding.new(what: "the game's tables", fix: "make its tables shorter, or use fewer of them")
          ROUTINES = W65816::Holding.new(what: "the game's routines", fix: "make its routines shorter, or use fewer of them")

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          R0 = Memory.register(0)
          R1 = Memory.register(1)

          # The routine the game names +name+.
          def self.routine_label(name) = "routine #{name}"

          # The console this lowers for (BuildCache).
          CONSOLE = Console::SUPER_NINTENDO

          # What the Super Nintendo's lowering alone works out from the program, once a build for all
          # its tries (BuildCache#facts): what its background pictures' pixels come to
          # (Art::TileMemo), whether its scenes have backdrops of their own, and what the runtime
          # carries for each set of choices a try is built with (Runtime::Carries, SNES#build).
          class BuildFacts
            attr_reader :tile_memo

            def initialize(cache)
              @cache = cache
              @tile_memo = Art::TileMemo.new
              @carries = {}
            end

            # Whether a scene sets a backdrop of its own (Picture.scene_backdrops?).
            def scene_backdrops?
              @scene_backdrops = Picture.scene_backdrops?(@cache.program, @cache.handover) if @scene_backdrops.nil?
              @scene_backdrops
            end

            # What the runtime carries for a try built on +board+ with +choices+ (Runtime::Carries.of).
            def carries(board, **choices)
              @carries[[board, choices]] ||= Runtime::Carries.of(@cache.program, board: board, handover: @cache.handover,
                                                                                 stacking: @cache.stacking, row_bends: @cache.plan.row_bends, **choices)
            end

            # The variables kept in two bytes (HalfVariables), worked out once a build and again after
            # a try hands some over (#keep_whole).
            def half_variables
              @half_variables ||= HalfVariables.proven(@cache.program, @cache.plan, also_whole: handed_over.to_a)
            end

            # The variables a try found it needed whole (Lowering#place_of), kept whole on every try
            # after.
            def handed_over = @handed_over ||= Set.new

            def keep_whole(names)
              handed_over.merge(names)
              @half_variables = nil
            end
          end

          # Where each of the game's variables went, by its name, and each of its lists — [its place,
          # its capacity, the bytes a slot, its name] — once #sections has placed them; the label of
          # the routine the runtime runs at each frame boundary, or nil for a game with no timers; and
          # each routine's section, by its label, beside what that routine is to the author.
          attr_reader :variables, :lists, :frame_begins, :section_routines

          # Where each list a pool's layout moved keeps its slots, by the list, as a SlotPlace counted
          # from the end of the list's header (CartridgeHeadlessRun#slot_place_of): the headless run
          # reads them there.
          def slot_places
            @list_slots.each_with_object({}) do |(name, slots), places|
              place, = @lists.fetch(name)
              next unless slots.moved?(place)

              places[name] = PoolLayout::SlotPlace.new(area: name, offset: slots.base - (place + Runtime::Lists::HEADER),
                                                       stride: slots.stride, width: slots.width, scale: slots.scale)
            end
          end

          # The variables this build keeps in two bytes (HalfVariables), for reading them back.
          def half_variables_kept = @variables.keys.select { |name| half_variable?(name) }.to_set

          # Whether the cartridge counts the frames it spends setting up into the game's count of
          # frames since power-on, from the top of setting up (Runtime::Boot#emit).
          def counts_from_power_on? = Frames.counts_from_power_on?(@program)

          # +sprite_squares+ draws sprites' squares of 16×16 as one row of the table each (Art).
          # +screen_colors+ has each scene bring its own background colours in, and +sprite_colors+ its
          # own sprite colours, +sprite_tiles+ its own sprite tiles, and +background_tiles+ its own
          # background tiles (Art). +one_sprite_tile_set+ makes one set of a sprite's pictures for
          # all the lists of colours it wears (Picture#palette_in_places). +chip+ is a cartridge
          # with a Super FX, which runs the routines marked for it (Chip). +cache+ is what the build
          # works out from the program once for all its tries (BuildCache), its background pictures'
          # pixels among it (Art::TileMemo). +scene_recordings+ has each scene bring its own recordings
          # into the sound unit (Runtime::Sound, "Each scene's recordings"). +shared_held_lists+ has the
          # short lists one background changes share a set of colours (Art). +lean_square_scenes+ and
          # +small_sprite_scenes+ are the crowded scenes whose sprites give up squares (Art).
          def initialize(program, memory:, sprite_squares: true, screen_colors: false, sprite_colors: false, sprite_tiles: false,
                         background_tiles: false, lean_square_scenes: {}, small_sprite_scenes: [], one_sprite_tile_set: false,
                         chip: false, scene_recordings: false, shared_held_lists: false, cache: BuildCache.for(SNES, program))
            @program = program
            @shared_held_lists = shared_held_lists
            @scene_recordings = scene_recordings
            @cache = cache
            @tile_memo = cache.facts.tile_memo
            @one_sprite_tile_set = one_sprite_tile_set
            @lean_square_scenes = lean_square_scenes
            @small_sprite_scenes = small_sprite_scenes
            @memory = memory
            @sprite_squares = sprite_squares
            @screen_colors = screen_colors
            @sprite_colors = sprite_colors
            @sprite_tiles = sprite_tiles
            @scene_background_tiles = background_tiles
            # What the program is before any instruction is made, worked out as the Color's is
            # (LoweringPlan), once a build, and kept here under the names the rest of the lowering reads.
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
            @list_slots = {}
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @cell_tables = {} # the words a picked tile's cells hold (Picture#emit_set_picked_tile_on) -> their table's label
            @section_routines = {}
            @cuts = RoutineCuts.for(self, cache)
            # A Super FX reads the lists it is handed in the slots they were declared with.
            @list_widths = chip ? {} : lists_kept_in_halves
            @unsigned_lists = @list_widths.keys.to_set & @plan.number_ranges.unsigned_half_lists.to_set
            prepare_picture
            prepare_paint
            prepare_collision
            prepare_sound
            prepare_chip(chip)
            # A Super FX reads and writes the variables its routines name in four bytes (ChipCode).
            @half_variables = chip ? Set.new : cache.facts.half_variables
            @handed_over = Set.new
          end

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            @plan.refuse_unbuildable!(not_lowered_yet: NOT_LOWERED_YET, not_made_yet: NotMadeYet, makes_followed_lists: false)
            # The see-through amounts a Super Nintendo cannot mix: an even half is made, and
            # Picture#refuse_see_through_amounts! refuses another, explaining why.
            refuse_see_through_amounts!
            refuse_what_chip_cannot_run!
            refuse_unmade_picture!
            refuse_unsupported_save_memory!
            assign_background_layers unless painted?
            make_sprite_art
            keep_sprite_colors_from_painting
            make_shared_background_colors
            reserve_patches
            # ...and the ones a game loop keeps of its own in the console's order (IR::Frames::ConsoleLoop).
            loops = @plan.game_loops.flat_map { |node| console_loop(node).variables }
            place_variables(Reach.variables(@program) | loops)
            place_chip_lists
            strided = strided_pool_placements
            @declared_lists.each_value do |node|
              width = LoweringPlan::SLOT_BYTES.fetch(list_width(node))
              # A list a pool's layout keeps elsewhere has only its header here.
              slots = strided.key?(node.name) ? 0 : node.capacity * width
              place = chip_list_place(node.name) ||
                      @memory.reserve_far("the list #{node.name.inspect}", Runtime::Lists::HEADER + slots)
              @lists[node.name] = [place, node.capacity, width, node.name.to_s]
              @list_slots[node.name] = ListSlots.new(header: place, base: place + Runtime::Lists::HEADER, stride: width,
                                                     width: width, scale: 1)
            end
            place_pool_slots(strided)
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            keep_corner_notes(corner_layers, bar: :own_note)
            keep_background_color_choices
            keep_sprite_color_choices
            keep_scene_tiles_up
            keep_turn_recordings_up
            keep_loop_running
            keep_column_numbers
            keep_order_tables
            make_chip_code
            routines = @called.flat_map do |name|
              next [] if @sorts_written_in_place.include?(name)
              next [chip_routine_section(name)] if on_chip?(name)

              @lowering_scene = @scenes.key?(name) ? name : nil
              with_call_numbers_recorded_for(name) do
                routines_fitting(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
              end
            end
            timers = timer_sections
            @lowering_scene = nil
            bend_routine = bend_sections
            main = routines_fitting(MAIN, @program.children, routine: "the game loop")
            columns = column_sections
            [data_section, *table_sections, *routines, *timers, *bend_routine, *main, *columns, *chip_sections]
          end

          # Whether the game has a division only a runtime routine can do (Runtime::Int32), once
          # #sections has lowered it.
          def divides? = @divides || false

          # Whether the game multiplies or divides numbers with a fraction (Runtime::Int32's rt_mul_fix
          # and rt_div_fix), once #sections has lowered it.
          def fractions? = @fractions || false

          # Whether the game moves a whole list to or from save memory, so its runtime carries the
          # routines that do it as a block (Runtime::Saving#emit_list_moves).
          def moves_lists_to_save? = SaveListMoves.moved_in?(@program)

          # Whether the game copies a list's items into a list of bytes as one run, so its runtime
          # carries the routine that finds the runs (Runtime::Lists#emit_pack), once #sections has
          # placed the lists.
          def packs_lists? = @reachable.any? { |node| node.kind == :list_pack && list_pack_block?(node) }

          private

          # Whether the slots of a list_pack's two lists are a copy's (ListPackBlocks): the list read
          # kept at the width it declares and the one written into in bytes, each one run of slots
          # from just after its header, and the one written into never taken from its front, so its
          # slot nought is the first after its header. A list of halves read back with no sign is a
          # list of words to the step, kept in two bytes, so the width alone sends it to the loop.
          def list_pack_block?(node)
            slots_contiguous?(node.name, ListPacking::WIDTH_BYTES.fetch(node.width)) && slots_contiguous?(node.into, 1) &&
              !front_dropped_lists.include?(node.into)
          end

          # Whether list +name+ keeps +bytes+ a slot, its slots one run from just after its header.
          def slots_contiguous?(name, bytes)
            place, _capacity, width, = @lists.fetch(name)
            slots = @list_slots.fetch(name)
            width == bytes && slots.base == place + Runtime::Lists::HEADER && slots.stride == width && slots.scale == 1
          end

          # The assembler a run of statements is measured in (MeasuredOnCopies#bytes_of).
          def measuring_assembler = W65816.new("measuring", holds: ROUTINES)

          # The bytes a run of statements made into +asm+ comes to once its section is made, with
          # its long branches and jumps in reach made short (W65816#shorten_long_branches), as the
          # routine it is measured for will be.
          def section_length(asm) = asm.section.bytes.bytesize

          # --- the data ---

          # The places that do not start at nought, each list's place, capacity and slot (the
          # runtime's start reads them), the tables of routines a call picks from by number, and the
          # tables of cell words a tile picked as the game runs is read from.
          def data_section
            asm = W65816.new("game data", holds: DATA)
            asm.label("game_starts")
            @starts.each do |address, value|
              asm.data_words(address, value & 0xFFFF, (value >> 16) & 0xFFFF)
            end
            asm.data_words(0)
            asm.label("game_lists")
            @lists.each do |name, (place, capacity, width, _)|
              asm.data_bytes(place & 0xFF, (place >> 8) & 0xFF, place >> 16)
              # Two bytes read with no sign are marked 3 in the header (Runtime::Lists::UNSIGNED_HALF).
              asm.data_words(capacity, unsigned_list?(name) ? Runtime::Lists::UNSIGNED_HALF : width)
            end
            asm.data_bytes(0, 0, 0)
            @routine_tables.each do |targets, label|
              asm.label(label)
              asm.data_longs(targets.map { |name| self.class.routine_label(name) })
            end
            @cell_tables.each do |words, label|
              asm.label(label)
              asm.data_words(words)
            end
            asm.section
          end

          # Each table a run reads, in a section of its own, so a long one gets a bank to itself.
          #
          # A table bigger than a bank is cut into parts (#split?), each a section of its own in
          # whatever bank it fits, and its label is then a list of where each part went, three bytes
          # a part. The bank a byte of the cartridge is in is the top of its address, and a LoROM
          # cartridge is only seen in the upper half of each bank, so the byte after a bank's last
          # is not the next bank's first: a read cannot simply run on from one part into the next.
          # So each part also holds, after its own entries, the first entries of the part after —
          # as many as the game ever copies into a list from the table at once — and a run copied
          # from anywhere in a part is all in that part.
          def table_sections
            tables_read.flat_map do |table|
              bytes, = table_keeping(table)
              next [table_section(table_label(table.name), values_kept(table), bytes)] unless split?(table)

              per = part_entries(table)
              refuse_copy_longer_than_part!(table)
              tail = most_copied(table)
              parts = (0...table.values.length).step(per).each_with_index.map do |from, part|
                table_section(part_label(table.name, part), table.values[from, per + tail], bytes)
              end
              places = W65816.new(table_label(table.name), holds: DATA)
              places.label(table_label(table.name))
              places.data_longs(parts.each_index.map { |part| part_label(table.name, part) })
              [places.section, *parts]
            end
          end

          def table_section(label, values, bytes)
            asm = W65816.new(label, holds: DATA)
            asm.label(label)
            asm.data_bytes(values.flat_map { |entry| little_endian(Int32.wrap(entry), bytes) })
            asm.section
          end

          def split?(table) = table.values.length * table_keeping(table).first > Linker::BANK_SIZE

          # How many of +table+'s entries a part holds of its own: a power of two, so which part an
          # entry is in is the top of its index, and where in the part the rest.
          def part_entries(table) = PART_BYTES / table_keeping(table).first

          def part_label(name, part) = "table #{name} part #{part + 1}"

          # The most entries a run reaches copies from +table+ at once.
          def most_copied(table)
            @reachable.select { |node| node.kind == :list_copy && node.table == table.name }.map(&:count).max || 0
          end

          # A copy from +table+ of more entries than a part holds of its own, refused: the part it
          # starts in does not hold the rest.
          def refuse_copy_longer_than_part!(table)
            most = most_copied(table)
            return if most <= part_entries(table)

            raise LoweringError, "The game copies #{most} entries of the table #{table.name.inspect} into a list in " \
                                 "one copy. The table is bigger than a bank of the Super Nintendo cartridge. For " \
                                 "this table, one copy can take a maximum of #{part_entries(table)} entries. To fix " \
                                 "this, copy fewer entries in each copy."
          end

          def tables_read = @plan.tables_read

          def table_label(name) = "table #{name}"

          def table_keeping(table) = @plan.table_keeping(table)

          def little_endian(value, size) = Array.new(size) { |i| (value >> (8 * i)) & 0xFF }

          # --- routines ---

          # A routine of +body+'s statements, or of what the block emits for one this lowering makes
          # for itself. +routine+ is what it is to the author.
          def routine_section(label, body, routine:)
            @section_routines[label] = routine
            @asm = W65816.new(label, holds: ROUTINES)
            @routine = label
            @labels = 0
            @asm.label(label)
            body.each { |node| statement(node) }
            yield if block_given?
            @asm.rtl
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
          #
          # It goes on the direct page where there is room: one read on +every_turn+ of a walk in the
          # room held for those (#place_variables), any in what the variables left. Then in the first
          # 8K while that has more room than the runtime still asks for after the lowering
          # (NEAR_BYTES_LAST), and past it after that, as the variables named least do.
          def keep_local(what, start: 0, every_turn: false)
            name = DerivedNames.local_number_name(@routine, what, @locals.length + 1)
            label = "the game's number #{name}"
            @locals[name] = if every_turn && @memory.direct_bytes_held >= 4
                              @memory.reserve_direct(label, 4, held: true)
                            elsif @memory.direct_bytes_left >= 4
                              @memory.reserve_direct(label, 4)
                            elsif @memory.near_bytes_left >= NEAR_BYTES_LAST + 4
                              @memory.reserve(label, 4)
                            else
                              @memory.reserve_far(label, 4)
                            end
            @starts << [@locals[name], start] unless start.zero?
            record_call_number(name, what)
            name
          end

          # The numbers each call of a routine keeps of its own (ControlFlow#call_numbers), put back
          # around the block's code, for every routine the frame boundary can call while a call of it is
          # waiting there (LoweringPlan#routines_reentered_at_frame_boundary): each pushed a half at a
          # time before, and pulled back after, so the call that waits goes on from its own loop's turn,
          # as the interpreter's does, whatever the boundary's call left there. A game whose boundary
          # calls no such routine has no code here. Around the timers, +kept+ is those and what a tick
          # handler that waits keeps (ControlFlow#numbers_kept_around_timers).
          def with_call_numbers_kept(kept = call_numbers)
            return yield if kept.empty?

            kept.each do |name|
              at = place_of(name)
              @asm.lda(at_place(at))
              @asm.pha
              @asm.lda(at_place(at + 2))
              @asm.pha
            end
            yield
            kept.reverse_each do |name|
              at = place_of(name)
              @asm.pla
              @asm.sta(at_place(at + 2))
              @asm.pla
              @asm.sta(at_place(at))
            end
          end

          # Where all four bytes of +name+ are. A variable kept in two (#half_variable?) has no such
          # place: asking for one notes it, and the try ends handing it over (#refuse_handed_over!),
          # so the next try keeps it whole. Code that reads or writes only a variable's low half asks
          # #kept_place_of.
          def place_of(name)
            @handed_over << name if half_variable?(name)
            kept_place_of(name)
          end

          # Where +name+'s first byte is, for code reading or writing only the bytes it is kept in.
          def kept_place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # Whether the variable +name+ is kept in two bytes (HalfVariables).
          def half_variable?(name) = @half_variables.include?(name)

          # A try asked for the whole place of a variable kept in two bytes (#place_of); the next try
          # keeps it whole (SNES#settings_after).
          class VariableHandedOver < StandardError; end

          # The try ends where it asked for the whole place of a variable kept in two bytes: its code
          # read four bytes there. The facts keep each whole from the next try on. Asked by SNES#build.
          public def refuse_handed_over!
            return if @handed_over.empty?

            @cache.facts.keep_whole(@handed_over)
            raise VariableHandedOver, "the try needs #{@handed_over.to_a.inspect} whole"
          end

          # The low half of variable +name+, as an operand: all of a variable kept in two bytes.
          def low_half_of(name) = at_place(kept_place_of(name))

          # What the lowering reads and writes a number at: a variable on the direct page, named by
          # its low byte; one in the rest of the first 8K, which every bank the code runs in can see;
          # or one past it, named by its whole address. Each costs a byte more and a cycle more each
          # time than the one before it. While D is on another page (#emit_sort_in_place) a direct
          # page variable is named by its 16-bit address, which reaches the same byte.
          def at_place(at)
            return @asm.long(at) if at > 0xFFFF
            return @asm.direct(at) if Memory.direct?(at) && !@direct_page_moved

            @asm.abs(at)
          end

          # Bytes of the first 8K left for what is kept after the variables: the routines' own
          # numbers, and what the runtime asks for as it is written.
          NEAR_BYTES_KEPT = 0x400

          # Bytes of the first 8K left for what the runtime asks for as it is written, after the
          # lowering: a routine's own numbers go past it rather than into these.
          NEAR_BYTES_LAST = 0x80

          # Every variable a place, the ones used most in the first 8K of work RAM. That is the part
          # the code reaches quickly, and a game with many numbers can want more of it than there
          # is. The ones it names least go past it, in the rest of the 128K: the game's own and the
          # ones the framework keeps for it (`__approach_2`) alike, since the lowering reads and
          # writes every one by the address it was given. A game that fits is laid out as it always
          # was. Only the variables the runtime reads by a 16-bit address stay near (NEAR_ONLY).
          #
          # And the busiest on the direct page, as many as fit in the room the runtime's scratch
          # leaves there (Memory#reserve_direct): chosen by how often the game names each, weighted
          # by the loops around it (Backends::VariableUse), and given their places before the rest so
          # that a game too big for the first 8K sends the least named far, not these. A direct page
          # place is also an address in the first 8K, so the runtime's own code, which reads a few
          # variables by their 16-bit address, finds them there all the same.
          #
          # A walk of a pool stepped the console's way (#emit_stepped_walk) reads numbers of its own
          # on every turn in place of the walk's variables, made only as the walk is lowered. Each
          # is ranked with the variable it stands in for, and room is held for it if it wins.
          def place_variables(names)
            chosen = direct_page_choices(names)
            direct = chosen.filter_map(&:variable)
            @memory.hold_direct_room(chosen.count { |choice| choice.variable.nil? } * 4)
            far = variables_kept_far(names - direct)
            direct.each { |name| @variables[name] = @memory.reserve_direct(variable_label(name), variable_bytes(name)) }
            (names - direct).each do |name|
              label = variable_label(name)
              bytes = variable_bytes(name)
              @variables[name] = far.include?(name) ? @memory.reserve_far(label, bytes) : @memory.reserve(label, bytes)
            end
          end

          def variable_label(name) = "the variable #{name.inspect}"

          # The bytes the variable +name+ is kept in: two for one proven to stay in 16 bits
          # (#half_variable?), all four of its number otherwise.
          def variable_bytes(name) = half_variable?(name) ? 2 : 4

          # What may go on the direct page, and how much the game names it: a variable, or (with no
          # variable) a number a stepped walk keeps of its own every turn, ranked as the walk's
          # variable it stands in for.
          DirectPageChoice = Data.define(:variable, :weight, :bytes)

          # What goes on the direct page, of +names+ and the stepped walks' own numbers: the busiest
          # that the game names at all, each taking its bytes of the room left there, until one does
          # not fit. Of equal weight, the first in +names+ first, and the walks' numbers after them.
          def direct_page_choices(names)
            use = @plan.variable_use
            choices = names.map { |name| DirectPageChoice.new(variable: name, weight: use.weight(name), bytes: variable_bytes(name)) }
            choices.concat(walk_numbers_by_weight(use))
            room = @memory.direct_bytes_left
            ranked = choices.select { |choice| choice.weight.positive? }.each_with_index.sort_by { |choice, i| [-choice.weight, i] }
            ranked.map(&:first).take_while { |choice| (room -= choice.bytes) >= 0 }
          end

          # The numbers each walk of a pool the run reaches keeps of its own every turn where it is
          # stepped (#emit_stepped_walk): the thing it goes to next, the last, and the thing it is on
          # scaled, each weighted as the walk's variable it stands in for. A walk the lowering does
          # not step its own way makes none of them, and the room held for its numbers goes to
          # whatever the lowering keeps of its own after.
          def walk_numbers_by_weight(use)
            @reachable.select { |node| node.kind == :repeat }.filter_map(&:pool_walk).flat_map do |walk|
              kept = [walk.ahead, (walk.last if @plan.chain_changed_during_walks?(walk.pool)), walk.at].compact
              kept.map { |name| DirectPageChoice.new(variable: nil, weight: use.weight(name), bytes: 4) }
            end
          end

          # The variables the runtime's own code reads by a 16-bit address: the music's volume,
          # which the tune's player reads (Runtime::Music#emit_level).
          NEAR_ONLY = [IR::Tunes::LEVEL].freeze

          # The variables that go past the first 8K, the ones named least, weighted by the loops around
          # each as the direct page's are (Backends::VariableUse): a number named once in a loop of
          # many turns stays near before one named twice a pass. Before any variable goes far the
          # runtime's tables do (Memory#reserve_table): the runtime reads those a few times a frame,
          # and the game's code reads its variables all the time. So a game that does not fit with
          # the tables near is built again with them far (SNES#build).
          def variables_kept_far(names)
            over = ((names.length * 4) - (@memory.near_bytes_left - NEAR_BYTES_KEPT)).ceildiv(4)
            return [] unless over.positive?
            raise @memory.near_full("the variable #{names.last.inspect}", 4) unless @memory.far_tables?

            use = @plan.variable_use
            (names - NEAR_ONLY).min_by(over) { |name| use.weight(name) }
          end

          # A routine of the game's, or the runtime's, called wherever it is.
          def call_routine(label) = @asm.jsl(@asm.long(label))

          # --- a routine too big for a bank, cut into parts ---

          # The most bytes one routine's code may come to before it is cut into parts, each a routine
          # of its own. A routine goes whole into one 32K bank (Linker), and the processor cannot run
          # on from the end of a bank into the next, so a routine is cut well before a bank is full:
          # what is left after the cut also has calls of its parts in it.
          MOST_ROUTINE_BYTES = 24_000

          # The most bytes a part cut off a routine may come to.
          MOST_PART_BYTES = 12_000

          # The routine +label+ of +body+'s statements, and the parts cut off it to fit a bank
          # (RoutineCuts#sections), each a section of its own; a part is called with a long call, so
          # it can be in any bank.
          def routines_fitting(label, body, routine:)
            @cuts.sections(label, body) { |part, statements| routine_section(part, statements, routine: routine) }
          end

          # The statements +node+ holds, and an `if`'s other side: as cut, when they were
          # (RoutineCuts#children_of).
          def children_of(node) = @cuts.children_of(node)

          # RTL, which ends every routine section: a byte.
          RETURN_BYTES = 1

          # What the lowering holds while it makes a statement (LoweringState). Copied all the way
          # down: the work RAM it reserves and the pictures, tiles and colours it gathers. Shared:
          # numbers, names, the program and what is worked out from it before any statement is made.
          # Left alone: the statements already cut into parts, which only cutting adds to, what the
          # build worked out once (BuildCache) and what the pictures' pixels come to (Art::TileMemo),
          # true whatever a measurement places.
          LOWERING_STATE = LoweringState.new(
            copied: [Memory, Art, PaintedArt, TextLayerArt],
            shared: [Integer, Symbol, String, NilClass, TrueClass, FalseClass, IR::Node, SceneHandover,
                     SpriteNames, Music, W65816, RoutineCuts::PartCall, LoweringPlan, ChipCode, Sound::ModeCall],
            unchanged: %i[@cuts @cache @tile_memo @keyed_sorts @keys_by_place @half_variables @handed_over @shown_sorts @shown_sort_nodes @unsigned_lists]
          )

          # --- statements ---

          def statement(node)
            return call_routine(node.label) if node.is_a?(RoutineCuts::PartCall)

            emit_statement(node)
          end

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # R0 into the variable +name+: its low half alone into one kept in two bytes, whose every
          # write is proven to fit them (HalfVariables).
          def store(name)
            @asm.lda(@asm.direct(R0))
            return @asm.sta(low_half_of(name)) if half_variable?(name)

            at = place_of(name)
            @asm.sta(at_place(at))
            @asm.lda(@asm.direct(R0 + 2))
            @asm.sta(at_place(at + 2))
          end

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var
            return emit_set_half(node.var, node.value) if half_variable?(node.var)

            known = folded(node.value)
            return store_number(place_of(node.var), known) if known
            return copy_variable(node.value, node.var) if variable_named(node.value)
            return emit_sum_into(node.value, variable_halves(node.var)) if sum_in_halves?(node.value) && !folded(node.value)
            return emit_slot_into_variable(node.value, node.var) if slot_read_into_variable?(node.value)

            value(node.value)
            store(node.var)
          end

          # A variable kept in two bytes set to +value+: only the low half of the number is worked out
          # (#emit_low_half), since the variable keeps nothing else, and stored with one STA. The
          # value is proven to fit 16 bits (HalfVariables), so those are the whole number with its sign.
          def emit_set_half(name, value)
            known = folded(value)
            return store_half_number(name, known) if known

            emit_low_half(value, 16)
            @asm.sta(low_half_of(name))
          end

          # A number written in the program into the variable +name+, kept in two bytes.
          def store_half_number(name, number)
            half = number & 0xFFFF
            return @asm.stz(low_half_of(name)) if half.zero? && kept_place_of(name) <= 0xFFFF

            @asm.lda(half)
            @asm.sta(low_half_of(name))
          end

          # A number written in the program into variable +name+, whatever it is kept in.
          def store_number_into(name, number)
            return store_half_number(name, number) if half_variable?(name)

            store_number(place_of(name), number)
          end

          # Whether +node+ is a list's slot read where it is, as #value_of_list_get reads one.
          def slot_read_into_variable?(node)
            plain_slot_read?(node)
          end

          # A list's slot straight into a variable: each half read and stored where it goes, a narrow
          # slot's sign spread into the high half as it is stored, where working it out into R0 and
          # storing that reads and writes every half twice. A pool's walk reads the next thing from its
          # list of links this way on every turn.
          def emit_slot_into_variable(node, name)
            place, _capacity, width = list_placed(node)
            slot = fixed_slot_address(node)
            unless slot
              emit_slot_into_x(place, list_slots(node).stride, index_halves(node.index),
                               checked: !index_inside_full_list?(node.name, node.index))
            end
            slots = slot || list_slots(node).base
            low, high = variable_halves(name)
            if width == 4
              [low, high].each_with_index do |to, i|
                @asm.lda(slot_operand(slots, 2 * i, slot.nil?))
                @asm.sta(to)
              end
              return
            end
            if unsigned_list?(node.name)
              @asm.lda(slot_operand(slots, 0, slot.nil?))
              @asm.sta(low)
              return @asm.stz(high) unless high.mode == :long # nothing stores a nought straight to a whole address

              @asm.lda(0)
              return @asm.sta(high)
            end

            positive = fresh("slot_positive")
            spread = fresh("slot_spread")
            @asm.lda(slot_operand(slots, 0, slot.nil?))
            if width == 1
              @asm.and_a(0x00FF)
              @asm.cmp(0x0080)
              @asm.bcc(positive)
              @asm.ora(0xFF00)
            else
              @asm.bpl(positive)
            end
            @asm.sta(low)
            @asm.lda(0xFFFF)
            if DSL::Pool.next_slot_of_walk?(name)
              # The walk's next slot holds a slot as its link is read (DSL::Pool::NEXT_SLOT_PARTS),
              # so its high half is nought already, and only NONE writes it.
              @asm.sta(high)
              @asm.bra(spread)
              @asm.label(positive, join: true)
              @asm.sta(low)
              return @asm.label(spread, join: true)
            end

            @asm.bra(spread)
            @asm.label(positive)
            @asm.sta(low)
            @asm.lda(0)
            @asm.label(spread)
            @asm.sta(high)
          end

          # Where the variable +name+'s two halves are, as operands.
          def variable_halves(name)
            at = place_of(name)
            [at_place(at), at_place(at + 2)]
          end

          # One variable into another, a half at a time from where it is: four instructions, where
          # working it out into R0 first and storing it from there is eight. A pool's walk does this
          # several times for each thing it visits.
          #
          # A variable a pool keeps only slots in (DSL::Pool::SLOT_ONLY_PARTS) is only ever set to a
          # slot, below the pool's capacity, and starts at nought, so its high half is nought for good:
          # only the low half is copied into one.
          #
          # The slot a walk is on is read at straight after, as the index of the walk's lists of bytes
          # (DSL::Pool::WALK_SLOT_PARTS), so it is put in X as well while A holds it: one instruction,
          # where reading it back for each list is two, on each side of the walk's test of whether
          # this is its last thing.
          def copy_variable(from, name)
            return copy_into_half(from, name) if half_variable?(name)
            return copy_half_into_whole(variable_named(from), name) if half_variable?(variable_named(from))

            halves = operand_halves(from)
            at = place_of(name)
            copied = DSL::Pool.holds_only_slots?(name) ? 1 : 2
            copied.times do |i|
              @asm.lda(halves[i])
              @asm.sta(at_place(at + (2 * i)))
            end
            stride = walk_stride(name)
            key = slot_key(at_place(at), stride)
            # A holds the low half, the slot, only when that was the one half copied.
            return unless DSL::Pool.walk_slot?(name) && key && copied == 1

            (stride - 1).bit_length.times { @asm.asl }
            @asm.tax
            @asm.note_x_holds(key)
            @asm.note_accumulator_holds(key.first) if stride == 1
          end

          # The variable +from+ names into +name+, kept in two bytes: its low half, all a copy proven
          # to fit them needs.
          def copy_into_half(from, name)
            @asm.lda(low_half_of(variable_named(from)))
            @asm.sta(low_half_of(name))
          end

          # The variable +from+, kept in two bytes, into +name+, kept whole: its low half, and its
          # sign spread over the high half.
          def copy_half_into_whole(from, name)
            at = place_of(name)
            @asm.lda(low_half_of(from))
            @asm.sta(at_place(at))
            emit_sign_of_a
            @asm.sta(at_place(at + 2))
          end

          # A = $FFFF where the 16-bit number the flags were last set from is below nought, and nought
          # otherwise: the high half of that number made whole. Its N flag decides, as a load sets it.
          def emit_sign_of_a
            positive = fresh("half_positive")
            spread = fresh("half_spread")
            @asm.bpl(positive)
            @asm.lda(0xFFFF)
            @asm.bra(spread)
            @asm.label(positive)
            @asm.lda(0)
            @asm.label(spread)
          end

          # The stride X is set to the walked slot at: the one every slot list of the walk's pool
          # shares in a layout of the console's own, so every field of the thing is read at that X;
          # one, for the byte lists a pool kept as lists steps along.
          def walk_stride(name)
            pool = DSL::Pool.walked_by(name)
            shape = pool && (@program.pools || []).find { |each| each.name.to_s == pool.to_s }
            strided = shape && shape.slot_lists.keys.filter_map { |list| strided_pool_placements[list] }.first
            strided ? strided.stride : 1
          end

          # A number written in the program, straight into the variable at +at+.
          def store_number(at, number)
            number &= 0xFFFF_FFFF
            [number & 0xFFFF, number >> 16].each_with_index do |half, i|
              if half.zero? && at <= 0xFFFF # nothing stores a nought straight to a whole address
                @asm.stz(at_place(at + (2 * i)))
              else
                @asm.lda(half)
                @asm.sta(at_place(at + (2 * i)))
              end
            end
          end

          # The carry readied for a sum written a half at a time (IN_PLACE_OPS): cleared before an add,
          # set before a subtract; AND, OR and XOR carry nothing.
          def emit_carry_for(operator)
            case operator
            when :+ then @asm.clc
            when :- then @asm.sec
            end
          end

          # A with +operator+ and +operand+, one half of a sum: an add or subtract goes on with the
          # carry from the half below.
          def emit_half_sum(operator, operand)
            case operator
            when :+ then @asm.adc(operand)
            when :- then @asm.sbc(operand)
            when :& then @asm.and_a(operand)
            when :| then @asm.ora(operand)
            when :^ then @asm.eor(operand)
            else raise LoweringError, "#{operator.inspect} is not worked out a half at a time"
            end
          end

          def emit_add(node) = emit_sum(node.var, :+, node.operand)
          # A count kept in Y taken back by one as its loop runs out (ControlFlow#emit_repeat) is a DEY.
          def emit_sub(node)
            return @asm.dey if node.var == @y_counter && folded(node.operand) == 1

            emit_sum(node.var, :-, node.operand)
          end

          # `x = x + n` and `x = x - n`, added where x is when n is a number written in the program or
          # a variable: six instructions and no call.
          #
          # When n has to be worked out it is worked out into R0 first and added from there: x is
          # only read and written by the sum itself, so working n out first reads the same x.
          def emit_sum(name, op, operand)
            return emit_set_half(name, Build.binop(op, Build.var_ref(name), operand)) if half_variable?(name)
            # INC and DEC reach only the first 64K (#emit_sum_of_half).
            if %i[+ -].include?(op) && half_variable?(variable_named(operand)) && kept_place_of(name) <= 0xFFFF
              return emit_sum_of_half(name, op, variable_named(operand))
            end

            right = operand_halves(operand)
            unless right
              value(operand)
              right = [@asm.direct(R0), @asm.direct(R0 + 2)]
            end

            at = place_of(name)
            emit_carry_for(op)
            2.times do |i|
              @asm.lda(at_place(at + (2 * i)))
              emit_half_sum(op, right[i])
              @asm.sta(at_place(at + (2 * i)))
            end
          end

          # `x += h` and `x -= h` for a whole x and an h kept in two bytes, whose high half is nought or
          # all ones by its sign. The low halves are added with the carry, and the high half of x
          # takes the carry and the sign each as a step of one, where both are usually nought: an INC
          # or DEC of memory, branched past, rather than h made whole first.
          def emit_sum_of_half(name, op, half)
            at = place_of(name)
            past_carry = fresh("no_carry")
            past_sign = fresh("not_negative")
            emit_carry_for(op)
            @asm.lda(at_place(at))
            emit_half_sum(op, low_half_of(half))
            @asm.sta(at_place(at))
            # The carry is set by a carry out of an add, and by no borrow out of a subtract.
            if op == :+
              @asm.bcc(past_carry)
              @asm.inc(at_place(at + 2))
            else
              @asm.bcs(past_carry)
              @asm.dec(at_place(at + 2))
            end
            @asm.label(past_carry)
            @asm.lda(low_half_of(half))
            @asm.bpl(past_sign)
            # A negative h has a high half of all ones: one less, added; one more, taken away.
            if op == :+
              @asm.dec(at_place(at + 2))
            else
              @asm.inc(at_place(at + 2))
            end
            @asm.label(past_sign)
          end

          def emit_copy(node)
            return if node.dest == node.src
            return copy_variable(node.src, node.dest) if variable_named(node.src)

            value(node.src)
            store(node.dest)
          end

          def emit_negate(node)
            value(node.var)
            emit_negate_r0
            store(node.var)
          end

          def emit_abs(node)
            value(Build.absolute(Build.var_ref(node.var)))
            store(node.var)
          end

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def emit_negate_abs(node)
            done = fresh("not_above_nought")
            jump_unless(Build.binop(:>, Build.var_ref(node.var), Build.int(0)), done)
            emit_negate(node)
            @asm.label(done)
          end

          def emit_clamp(node)
            value(Build.clamped(Build.var_ref(node.var), node.min, node.max))
            store(node.var)
          end

          # --- what ControlFlow asks of a lowering, in the 65816's instructions ---

          # The labels a test's two sides end at (ControlFlow#emit_if) are reached only from above,
          # by the test and by the end of its first side, so they are joins (W65816#label).
          JOIN_LABELS = %w[else end_if].freeze

          def fresh_label(what)
            label = fresh(what)
            (@join_labels ||= {})[label] = true if JOIN_LABELS.include?(what)
            label
          end

          def place_label(label) = @asm.label(label, join: (@join_labels || {}).key?(label))
          def jump(label) = @asm.jump(label)
          def emit_value(operand) = value(operand)
          def emit_store(name) = store(name)
          def emit_store_zero(name)
            store_number_into(name, 0)
            return unless name == @y_counter

            @asm.ldy(0)
            note_y_counter(name)
          end

          def emit_copy_variable(from, to) = copy_variable(from, to)
          def emit_increment(name)
            if name == @y_counter
              refuse_y_changed!(name)
              @asm.iny
              return note_y_counter(name)
            end

            at = kept_place_of(name)
            return @asm.inc(at_place(at)) if (short_counter?(name) || half_variable?(name)) && at <= 0xFFFF

            emit_sum(name, :+, Build.int(1))
          end

          # A loop's count that cannot leave its low half: a repeat whose number of turns is written in
          # the program and below $8000 counts from nought to that number, so the high half of its
          # count is the nought it started with on every turn. Each turn ends adding one and
          # comparing with the number of turns, and a 32-bit sum and a signed compare of both halves
          # are thirteen instructions there; an INC of the low half and an unsigned compare of it are
          # three. A pool's walk is such a loop, with a turn for every thing it visits. The count is
          # still a whole number in its variable, for the body and for after the loop, since the high
          # half is never written but by the nought the loop starts with.
          #
          # And in Y, where nothing reads the count but the loop (a `repeat` whose index the body never
          # names, as most loops written `repeat(n) { ... }` are) and nothing in the loop changes Y. An
          # INC of a count in work RAM is eight cycles at sixteen bits and the compare loads it again;
          # INY and CPY with the number are two and three (cycle counts in fullsnes and the SNESdev
          # wiki's 65816 reference), the way the console's own loops count. Whether the loop leaves Y
          # alone is known only once it is written (W65816#y_changes), so it is written first on copies
          # of the lowering's state and thrown away (#y_kept_through?). The count is still nought in
          # its variable from the start, and Y is written to it once, as the loop ends.
          def with_counter_held(node, counter, loaded: false)
            known = short_count_of(node, loaded)
            return yield unless known && known < 0x8000

            in_y = @y_counter.nil? && kept_place_of(counter) <= 0xFFFF && turns_countable_in_y_register?(node, counter, loaded)
            (@short_counters ||= {})[counter] = known
            @y_counter = counter if in_y
            if in_y && loaded
              @asm.ldy(low_half_of(counter))
              note_y_counter(counter)
            end
            begin
              yield
            ensure
              @short_counters.delete(counter)
              @y_counter = nil if in_y
            end
            @asm.sty(low_half_of(counter)) if in_y
          end

          # Whether a short count of the loop +node+, +counter+, can be counted in Y: only the loop
          # names it (it is the repeat's own index, or the loop has none of the game's; or, +loaded+, a
          # counted while's variable, which only its one more names), nothing in the loop can reach a
          # frame boundary or stop the game, and nothing written for the body or the test to stop
          # changes Y.
          def turns_countable_in_y_register?(node, counter, loaded)
            return false unless loaded || node.index.nil? || node.index == counter

            body = loaded ? children_of(node).first[0...-1] : children_of(node).first
            # A part cut off a body too big for a bank is called (RoutineCuts), and a call can change Y.
            return false if body.any?(RoutineCuts::PartCall)

            # A counted while asks only at its end, the compare of the count (ControlFlow#emit_counted_while).
            asked = loaded ? [] : [Build.if_(node.stop_when)]
            nodes = Reach.statements_from(*body, *asked)
            return false if nodes.any? { |each| %i[raw halt].include?(each.kind) || each.attrs.values.flatten.include?(counter) }
            return false if @plan.statements_wait?(nodes)

            y_kept_through?(body + asked)
          end

          # Whether +statements+, written into an assembler of their own on copies of the lowering's
          # state (as MeasuredOnCopies#bytes_of measures them), leave Y as it was.
          def y_kept_through?(statements)
            LOWERING_STATE.on_copies(self) do
              measuring = @asm = measuring_assembler
              @routine = "measuring"
              @labels = 0
              statements.each { |each| statement(each) }
              @asm.equal?(measuring) && measuring.y_changes.zero?
            end
          end

          # Y, holding the short count +name+ (#with_counter_held), checked to hold it still: what the
          # loop wrote since it was set must not have changed it, as #y_kept_through? found.
          def refuse_y_changed!(name)
            return if @asm.equal?(@y_section) && @asm.y_changes == @y_changes_at

            raise LoweringError, "the count #{name.inspect} was kept in Y and something in its loop changed Y"
          end

          # Y set or stepped for the count +name+, and what Y was changed by up to here noted.
          def note_y_counter(name)
            @y_section = @asm
            @y_changes_at = @asm.y_changes
            name
          end

          # The number a loop's count stays below, where it is written in the program: a repeat's
          # count, or a counted while's limit where its start is written just before it at nought or
          # above (LoopForm#counted_while), so its high half is the nought that start gave it. Nil
          # where either is not known.
          def short_count_of(node, loaded)
            return folded(node.count) unless loaded

            counted = loop_form.counted_while(node)
            limit = folded(counted.limit)
            limit if counted.starts_at&.between?(0, limit || -1)
          end

          # Whether +name+ is a loop's count that stays in its low half (#with_counter_held).
          def short_counter?(name) = (@short_counters || {}).key?(name)

          # Two of a pool's slots tested equal, or not: `other.index != e.index`, a pool thing passing
          # over itself as it walks the others. A variable a pool keeps a slot in holds one below the
          # pool's capacity whenever it is read (DSL::Pool::SLOT_PARTS), so its high half is nought and
          # the low halves alone answer. The branch taken when the test does not hold, or nil.
          def compare_pool_slots(node)
            return unless %i[== !=].include?(node.op)

            names = [node.lhs, node.rhs].map { |side| variable_named(side) }
            return unless names.all? { |name| name && DSL::Pool.walked_by(name) }
            return compare_scaled_current(node.op, *names) if @scaled_currents&.key?(names[0])
            return compare_scaled_current(node.op, *names.reverse) if @scaled_currents&.key?(names[1])

            emit_low_half_load(at_place(place_of(names[0])))
            @asm.cmp(at_place(place_of(names[1])))
            node.op == :== ? :bne : :beq
          end

          # The thing a walk is on, held as a ScaledCurrent under +name+, compared with the thing in
          # +other+, scaled before the walk: X with it where X holds the walk's place, else the place
          # stored. Equal places are equal slots, and NONE, $FFFF, is no slot's place.
          def compare_scaled_current(op, name, other)
            current = @scaled_currents.fetch(name)
            partner = at_place(current.partners.fetch(other))
            if @asm.x_holds == [current.at, current.stride]
              @asm.cpx(partner)
            else
              @asm.lda(at_place(current.scaled))
              @asm.cmp(partner)
            end
            op == :== ? :bne : :beq
          end

          # LDA of a variable's low half, unless A holds it already (W65816#accumulator_holds): a pool's walk
          # stores the slot it is on and then compares it and reads lists at it straight after. Only
          # where what follows sets the flags itself (a compare, a shift), as the load it saves would.
          def emit_low_half_load(operand)
            address = operand.value + operand.plus if variable_operand?(operand)
            return if address && @asm.accumulator_holds == address

            @asm.lda(operand)
            @asm.note_accumulator_holds(address) if address
          end

          # Whether +operand+ names a variable's place by its address: a 16-bit one, or a direct page
          # one past the working numbers, which the lowering's own code writes only through R0.
          def variable_operand?(operand)
            return false unless operand.is_a?(W65816::Operand) && operand.value.is_a?(Integer)

            operand.mode == :abs || (operand.mode == :dp && operand.value >= Memory::SCRATCH)
          end

          # The low half of a short counter compared, unsigned, with a number written in the program
          # below $8000 that it is less than: the branch taken when it is not, or nil for any other
          # comparison.
          def compare_short_counter(node)
            return unless node.op == :< && node.lhs.is_a?(Node) && node.lhs.kind == :var_ref && short_counter?(node.lhs.name)

            number = folded(node.rhs)
            return unless number&.between?(0, 0x7FFF)

            if node.lhs.name == @y_counter
              refuse_y_changed!(@y_counter)
              @asm.cpy(number)
              return :bcs
            end
            @asm.lda(low_half_of(node.lhs.name))
            @asm.cmp(number)
            :bcs
          end
          def loop_statements(node) = children_of(node).first
          def game_loops = @plan.game_loops
          def loop_form = @plan.loop_form

          def console_loop(node) = @plan.console_loop(node)

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)
            return emit_sort_in_place(@funcs.fetch(node.target).children) if @sorts_written_in_place&.include?(node.target)

            call_routine(self.class.routine_label(node.target))
          end

          # A draw order's routine written where it is called (#sort_written_in_place?), with D on
          # its tables' page while it runs when it has one (KeyedSort), and back on the game's page,
          # $0000, after. A sort handed +shown+ asks its things first, on the game's page (ShownSort).
          def emit_sort_in_place(body)
            sort = body.last
            keyed = @keyed_sorts.fetch(sort.name)
            shown = @shown_sorts&.fetch(sort.name, nil)
            emit_shown_asked_once(sort, shown, keyed) if shown
            page = keyed.page
            return body.each { |each_node| statement(each_node) } unless page

            @asm.lda(page)
            @asm.tcd
            begin
              @direct_page_moved = true
              body.each { |each_node| statement(each_node) }
            ensure
              @direct_page_moved = false
            end
            @asm.lda(0)
            @asm.tcd
          end

          # Reference#exec_call_one_of: the number worked out once, and a number naming no routine of
          # the list — below nought or past its end — calls nothing. Compared as a number that cannot
          # be negative, -1 is the biggest there is, so one test guards both ends. The routine is
          # reached through a table of their long addresses: its address pushed as RTL would find a
          # return address (one less, bank first), and RTL taken to it. A mode call first brings in
          # the recordings of the mode it picks (Sound#emit_mode_recordings).
          def emit_call_one_of(node)
            emit_mode_recordings(node)
            table = @routine_tables[node.targets] ||= "routines #{@routine_tables.length + 1}"
            none = fresh("calls_none")
            back = fresh("called")
            value(node.which)
            @asm.lda(@asm.direct(R0 + 2))
            @asm.branch_long(:bne, none)
            @asm.lda(@asm.direct(R0))
            @asm.cmp(node.targets.length)
            @asm.branch_long(:bcs, none)
            @asm.asl # × 3: an entry is three bytes
            @asm.adc(@asm.direct(R0)) # the carry is clear: the index is below the list's length
            @asm.tax
            # Where the called routine's RTL comes back to: the instruction after the RTL below.
            @asm.phk
            @asm.pea(@asm.abs(back, -1))
            @asm.sep(0x20)
            @asm.lda(@asm.long_x(table, 2))
            @asm.pha
            @asm.rep(0x20)
            @asm.lda(@asm.long_x(table))
            @asm.dec
            @asm.pha
            @asm.rtl
            @asm.label(back)
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
              @asm.brl(done)
            else
              emit_scene_number(number)
            end
            @asm.label(staying)
            call_routine(label)
            @asm.label(done)
          end

          # The note of the scene running now, set to +number+.
          def emit_scene_number(number)
            store_number(place_of(@scene), number)
            emit_scene_arrival(@scenes.key(number))
            emit_scene_recordings(@scenes.key(number))
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
            @asm.jml(@asm.long("rt_halt"))
          end

          # The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them
          # (Reference#store_frame_counters): the frames shown by every frame the pass took, and what
          # the game catches up by held at the cap, both as the runtime counted them.
          #
          # The rows of each background bent row by row come first (Reference#work_out_bends): the
          # wait's blank sends the scroll this pass placed, and a row's bend goes out with it.
          def emit_wait_vblank(_node)
            @plan.bends_in_own_routine? ? call_routine(BENDS) : emit_bends
            call_routine("rt_wait_vblank")
            emit_corners_forgotten
            count = place_of(Frames::COUNT)
            @asm.clc
            @asm.lda(at_place(count))
            @asm.adc(@asm.abs(@memory[Runtime::Frame::FRAMES_TAKEN]))
            @asm.sta(at_place(count))
            @asm.lda(at_place(count + 2))
            @asm.adc(0)
            @asm.sta(at_place(count + 2))
            step = place_of(Frames::STEP)
            @asm.lda(@asm.abs(@memory[Runtime::Frame::STEP_TAKEN]))
            @asm.sta(at_place(step))
            if step > 0xFFFF # nothing stores a nought straight to a whole address
              @asm.lda(0)
              @asm.sta(at_place(step + 2))
            else
              @asm.stz(@asm.abs(step + 2))
            end
            value(Frames::COUNT)
            store(Frames::SEEN)
          end

          # --- lists (Runtime::Lists does the work and the checking) ---

          # Reference::ListValue.of: empty, or holding its capacity of the one number it is full of.
          # A draw order's list, kept in tables of its own (#emit_keyed_sort), starts them here too.
          def emit_list_new(node)
            keyed = @keyed_sorts&.fetch(node.name, nil)
            emit_order_tables_start(keyed) if keyed
            shown = @shown_sorts&.fetch(node.name, nil)
            emit_shown_start(shown) if shown
            return list_call("rt_list_empty", node) unless node.full_of

            list_call("rt_list_at_capacity", node)
            return emit_strided_slots_filled(node) if strided_list?(node.name)
            return emit_slots_zeroed(node) if slots_zeroed_by_copying_engine?(node)

            list_call("rt_list_fill", node, Build.int(0), Build.int(node.capacity), Build.int(node.full_of))
          end

          # A pool list kept at its layout's stride, every slot made +full_of+: the runtime's fill
          # writes slots one after another from the header, so the slots are written here, each at
          # its place, a byte slot with A eight bits wide so the bytes beside it in a record are kept.
          def emit_strided_slots_filled(node)
            slots = list_slots(node)
            width = slots.width
            again = fresh("strided_fill")
            kept = slots.scaled? && node.full_of != DSL::Pool::NONE ? node.full_of * slots.scale : node.full_of
            number = kept & 0xFFFF
            @asm.ldx(0)
            @asm.label(again)
            @asm.lda(number)
            @asm.sep(0x20) if width == 1
            @asm.sta(@asm.long_x(slots.base))
            @asm.rep(0x20) if width == 1
            if width == 4
              @asm.lda((node.full_of >> 16) & 0xFFFF)
              @asm.sta(@asm.long_x(slots.base, 2))
            end
            @asm.txa
            @asm.clc
            @asm.adc(slots.stride)
            @asm.tax
            @asm.cpx(node.capacity * slots.stride)
            @asm.bcc(again)
          end

          # A list full of nought in work RAM has its slots cleared by the copying engine, a byte in
          # one slow cycle, rather than by the runtime's fill, which finds and writes each slot in
          # turn. A save record's table and buffers are declared so, and are made at power-on before
          # the game's first pass. A list in a Super FX's RAM is out of the work RAM port's reach.
          def slots_zeroed_by_copying_engine?(node)
            place, capacity, width, = list_placed(node)
            node.full_of.zero? && place >= Runtime::Picture::WORK_RAM && (capacity * width).between?(1, 0xFFFF)
          end

          def emit_slots_zeroed(node)
            _place, capacity, width, = list_placed(node)
            Runtime::Picture.emit_fill_work_ram(@asm, list_slots(node).base, capacity * width, "rt_zero")
          end

          def emit_list_push(node) = list_call("rt_list_push", node, node.value)
          def emit_list_drop(node) = list_call("rt_list_drop", node, Build.int(node.from == :front ? 1 : 0))
          def emit_list_fill(node) = list_call("rt_list_fill", node, node.from, node.count, node.value)

          # A list_pack's run copied by the console's block move (ListPackBlocks). The runtime finds
          # the runs (Runtime::Lists#emit_pack): the list's items go round its slots like a ring, so
          # they are at most two. Each is one MVN, which moves A+1 bytes from X in one bank to Y in
          # another, seven cycles a byte (fullsnes, "65XX Block Move"); the two banks are the lists',
          # known here, so the instruction is written here rather than in the runtime. MVN leaves the
          # data bank at the one it wrote to, and it is put back.
          def emit_list_pack_block(node)
            into = @lists.fetch(node.into).first
            from = list_place(node)
            list_call("rt_list_pack", node, Build.int(into), node.at)
            @asm.phb
            [[Runtime::Lists::R3, nil], [Runtime::Lists::R4, Runtime::Lists::R5]].each do |count, source|
              none = fresh_label("list_pack_none")
              @asm.lda(@asm.direct(count))
              @asm.beq(none)
              @asm.ldx(@asm.direct(source)) if source
              @asm.dec # MVN moves one more than A
              @asm.mvn(into >> 16, from >> 16)
              place_label(none)
            end
            @asm.plb
          end

          # How many a list holds is a word of its header, read where it is: three instructions, where
          # the runtime's call takes the list's place handed over, the jump there and back, and the
          # header found from the place. A pool asks it of its retired things at the end of every walk.
          def value_of_list_len(node)
            @asm.lda(@asm.long(list_place(node), Runtime::Lists::LENGTH))
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end

          # A list nothing takes from the front keeps its first item in its first slot for good, so an
          # item's slot is its index, and its place is known here: one load with X as the index, past
          # one test that the index is inside the list. The runtime's way finds the place from the
          # list's header, which takes as long as ten sums, and a game walking a map held in a list
          # does this many times a pass.
          def value_of_list_get(node)
            kept = kept_read(node)
            return load_variable(kept) if kept
            return list_call("rt_list_get", node, node.index) if front_dropped_lists.include?(node.name)
            return emit_scaled_slot_read(node) if list_slots(node).scaled?

            place, _capacity, width = list_placed(node)
            unsigned = unsigned_list?(node.name)
            slot = fixed_slot_address(node)
            return emit_read_slot_at_x(slot, width, x: false, unsigned: unsigned) if slot

            slots = list_slots(node)
            emit_slot_into_x(place, slots.stride, index_halves(node.index), checked: !index_inside_full_list?(node.name, node.index))
            emit_read_slot_at_x(slots.base, width, unsigned: unsigned)
          end

          # Whether list +name+ is kept in half words read back with no sign (#lists_kept_in_halves).
          def unsigned_list?(name) = @unsigned_lists.include?(name)

          # The lists kept in half words read back with no sign, for reading them back (Places).
          public def unsigned_lists = @unsigned_lists.to_a

          # Where the slot is, when the index is a number written in the program that is always
          # inside the list (#index_inside_full_list?): the read or write then names the slot
          # itself, with no index worked out at all. Nil otherwise.
          def fixed_slot_address(node)
            number = folded(node.index)
            return nil unless number && index_inside_full_list?(node.name, node.index)

            list_slots(node).at(number)
          end

          # Where the two halves of +node+ are when it reads a whole-word slot at a fixed address
          # (#fixed_slot_address), so a copy from one word slot to another is two loads and two
          # stores; nil for anything else.
          def fixed_word_slot_halves(node)
            return nil unless node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name)

            slot = list_placed(node)[2] == 4 && fixed_slot_address(node)
            slot ? [@asm.long(slot), @asm.long(slot, 2)] : nil
          end

          # The operand naming a slot: +slots+ plus X, or +slots+ itself when +x+ is false.
          def slot_operand(slots, plus, x) = x ? @asm.long_x(slots, plus) : @asm.long(slots, plus)

          # Reference#exec_list_set: the index worked out, then the value, then the test. An index
          # that is a variable or a written number is read where it is, after the value: working a
          # value out never changes a variable, so it reads the same.
          def emit_list_set(node)
            keyed = @keys_by_place&.fetch(node.name, nil)
            return emit_key_by_place(node, keyed) if keyed
            return list_call("rt_list_set", node, node.index, node.value) if front_dropped_lists.include?(node.name)
            return emit_scaled_slot_write(node) if list_slots(node).scaled?

            place, _capacity, width = list_placed(node)
            stride = list_slots(node).stride
            halves = operand_halves(node.value)
            slot = fixed_slot_address(node)
            halves ||= fixed_word_slot_halves(node.value) if slot && width == 4
            if slot
              # A word's sum is written straight into its slot, a half at a time.
              if !halves && width == 4 && sum_in_halves?(node.value) && %i[+ -].include?(node.value.op)
                return emit_sum_into(node.value, [@asm.long(slot), @asm.long(slot, 2)])
              end

              unless halves
                slot_value(node.value, width)
                halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
              end
              return emit_write_slot_at_x(slot, width, halves, x: false)
            end

            index = index_in_place(node.index)
            checked = !index_inside_full_list?(node.name, node.index)
            if halves
              emit_slot_into_x(place, stride, index_halves(node.index), checked: checked)
            elsif index
              slot_value(node.value, width)
              emit_slot_into_x(place, stride, index, checked: checked)
              halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
            else
              push_value(node.index)
              slot_value(node.value, width)
              pull_into(R1)
              emit_slot_into_x(place, stride, [@asm.direct(R1), @asm.direct(R1 + 2)], checked: checked)
              halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
            end
            emit_write_slot_at_x(list_slots(node).base, width, halves)
          end

          # Where a list's index can be read without working anything out, as #emit_slot_into_x takes
          # it: both halves of a written number or a whole variable (#operand_halves), or the low half
          # alone of a variable kept in two bytes, with no high half; nil otherwise.
          def index_in_place(index)
            halves = operand_halves(index)
            return halves if halves

            name = variable_named(index)
            [low_half_of(name), nil] if half_variable?(name)
          end

          # Where the two halves of a list's index are: where a variable or a written number already
          # is, or R0 once it is worked out.
          def index_halves(index)
            halves = index_in_place(index)
            return halves if halves

            value(index)
            [@asm.direct(R0), @asm.direct(R0 + 2)]
          end

          def front_dropped_lists
            @front_dropped_lists ||= @reachable.filter_map { |node| node.name if node.kind == :list_drop && node.from == :front }.uniq
          end

          def list_placed(node)
            @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }
          end

          # Where a list's slots are: its header (where the runtime keeps its capacity, front and
          # length), slot 0, and the bytes from one slot to the next. A list of the game's own has its
          # slots straight after its header, a slot as wide as the list. A pool's slot lists are where
          # its layout put them (Backends::PoolLayout, #place_pool_slots): today's lists the same way,
          # another layout at a stride every list of the pool shares. Every read and write of a slot
          # asks here, never the header's place plus the header.
          #
          # +width+ is the bytes a slot's value is kept in, and +scale+ what it is kept multiplied by:
          # the list's own width and 1, except a pool's link kept as the slot times the stride
          # (Backends::PoolLayout.strided_place), two bytes with NONE as $FFFF.
          ListSlots = Data.define(:header, :base, :stride, :width, :scale) do
            def at(slot) = base + (slot * stride)

            # Whether the slots are anywhere but straight after the header at +place+, each as wide as
            # the list and kept as the tree holds it.
            def moved?(place) = base != place + Runtime::Lists::HEADER || stride != width || scale != 1

            # Whether the values are kept multiplied (#emit_scaled_slot_read, #emit_scaled_slot_write).
            def scaled? = scale != 1

            # How many doublings the scale is.
            def scale_shifts = (scale - 1).bit_length
          end

          # The SlotPlace of each slot list of a pool kept in a layout other than :lists, by the list:
          # the layout chosen for each pool (Backends::PoolLayout.chosen), unless one of its lists
          # is in a Super FX's RAM, where the chip reads it as a list.
          def strided_pool_placements
            @strided_pool_placements ||= (@program.pools || []).each_with_object({}) do |declared, places|
              shape = declared.with(slot_lists: declared.slot_lists.to_h { |list, width| [list, @list_widths.fetch(list, width)] })
              placement = PoolLayout.chosen(shape, CONSOLE, PoolLayout.steps_on(@program, shape)).place(shape)
              next if placement.layout == :lists || shape.slot_lists.keys.any? { |list| chip_list_place(list) }

              (@pool_areas ||= {}).merge!(placement.areas)
              places.merge!(placement.slots)
            end
          end

          # Each pool's slot lists placed by the layout the pool is kept in (Backends::PoolLayout):
          # a list kept as :lists has its slots after its header, where #sections reserved them; one
          # kept in another layout has them in an area of the pool's, reserved here, at the layout's
          # stride.
          def place_pool_slots(strided)
            areas = (@pool_areas || {}).to_h { |area, bytes| [area, @memory.reserve_far("the pool area #{area.inspect}", bytes)] }
            strided.each do |list, place|
              next unless @lists.key?(list)

              @list_slots[list] = ListSlots.new(header: @lists.fetch(list).first, base: areas.fetch(place.area) + place.offset,
                                                stride: place.stride, width: place.width, scale: place.scale)
            end
          end

          # The slot a list is kept in: the one it was declared with, or a narrower one where every
          # number written to it is proven to fit (NumberRanges#list_widths), which keeps each exactly
          # and reads it back as the wider slot would: a pool's field of places on the screen kept in
          # two bytes, worked by the paths a field declared `widths: :half` takes.
          def list_width(node) = @list_widths.fetch(node.name, node.width)

          # The lists of whole words proven to hold only numbers of 16 bits or fewer
          # (NumberRanges#list_widths), each kept in half words. Not in bytes, though one may hold
          # only those: the 65816 reads a half word whole with its accumulator wide, where a byte
          # read into a number is the byte masked out, compared and its sign ORed in, so a game
          # adding a byte field into a whole one (`x += dx`) spends more than with the word.
          # And a pool's fields only where every field of whole words in it can be: a pool kept as
          # lists reads each field at X, the slot times the field's width, so fields of two widths
          # side by side set X again for each, where fields of one width share it. Measured on the
          # pool bullets test (x and y whole, their steps proven small): 6.9% of a frame with every
          # field a word, 9.5% with the steps in bytes, 7.3% in half words; left whole, as it was.
          #
          # A list proven to hold 0..65535 (NumberRanges#unsigned_half_lists) is kept in half words too,
          # read back with no sign (#unsigned_list?): a place in 256ths of a pixel kept with `& 0xFFFF`.
          def lists_kept_in_halves
            ranges = @plan.number_ranges
            proven = (ranges.list_widths.keys + ranges.unsigned_half_lists).select { |name| @declared_lists[name]&.width == :word }
            pooled, plain = proven.partition { |name| DSL::Pool.owner_of_list(name) }
            whole_fields = @declared_lists.values.select { |node| node.width == :word && DSL::Pool.owner_of_list(node.name) }
                                          .map(&:name) - proven
            kept = pooled.reject { |name| whole_fields.any? { |other| DSL::Pool.owner_of_list(other) == DSL::Pool.owner_of_list(name) } }
            (plain + kept).to_h { |name| [name, :half] }
          end

          # Whether +name+'s slots are kept other than straight after its header, a slot as wide as the
          # list: a pool list of a layout of the console's own.
          def strided_list?(name) = strided_pool_placements.key?(name)

          # Whether the repeat +node+ is a walk of a pool kept at one stride (IR::WalkShape) that
          # #emit_stepped_walk can step its own way: its count written in the program, an index to
          # count in, and no frame boundary anywhere in it, so nothing but the walk itself runs
          # while its own numbers are held.
          def stepped_walk?(node)
            walk = node.pool_walk
            return false unless walk && node.index && strided_list?(walk.links) && walk.step_statements == 2

            capacity = folded(node.count)
            !capacity.nil? && capacity.between?(1, 0x7FFF) && !@plan.statements_wait?(node.walk.to_a)
          end

          # A walk of a pool stepped as the console's own games step one. The tree's walk keeps the
          # thing it goes to next and the last it visits as 32-bit numbers, tests the next against
          # NONE in both halves, copies it into the thing it is on, compares that with the last, reads
          # the link out as 32 bits with its sign spread, and counts its turns to the pool's capacity.
          # The 65816's way is to hold the next thing's place in an index register, load its link
          # with one indexed load and end on a link of $FFFF (indexed addressing: fullsnes, "65XX CPU
          # Addressing Modes"; the SNESdev wiki's 65816 reference). Here
          # the next and the last are kept as the slot times the pool's stride, so the slot to visit
          # is X at once, NONE is $FFFF, a negative number, and every field of the thing is read at
          # that X; the thing it is on is written to its variable, as the body reads it.
          #
          # Every variable of the walk ends as the tree leaves it: the thing it was on, the next
          # (NONE), and the repeat's index, which counts the turns and stays one below the count
          # where the walk took every one (Reference#exec_repeat).
          def emit_stepped_walk(node)
            walk = node.pool_walk
            links = list_slots(walk.links)
            shifts = (links.stride - 1).bit_length
            ahead = place_of(keep_local(:walk_ahead, every_turn: true))
            # Where the chain cannot change while the walk runs, the last thing's link is NONE and
            # the walk stops on it alone (LoweringPlan#chain_changed_during_walks?), keeping no last.
            last = place_of(keep_local(:walk_last, every_turn: true)) if @plan.chain_changed_during_walks?(walk.pool)
            at = place_of(walk.at)
            index = place_of(node.index)
            # X, INC and DEC reach only the first 64K by their short address; a walk whose numbers
            # went further is walked the tree's way.
            return emit_control_flow_statement(node) if [ahead, last, at, index].compact.any? { |place| place > 0xFFFF }

            top = fresh("walk")
            done = fresh("walk_done")
            body = @plan.walk_body(node)
            current = scaled_current(walk, body, at, links.stride)
            store_number(index, 0)
            emit_slot_scaled(place_of(walk.ahead), ahead, shifts)
            emit_slot_scaled(place_of(walk.last), last, shifts) if last
            current&.partners&.each { |name, scaled| emit_slot_scaled(place_of(name), scaled, shifts) }
            store_number(current.scaled, DSL::Pool::NONE) if current
            counter = turns_countable_in_y?(node, body)
            @asm.ldy(0) if counter
            @asm.label(top)
            @asm.ldx(at_place(ahead))
            @asm.branch_long(:bmi, done)
            if current
              @asm.stx(at_place(current.scaled))
            else
              @asm.txa
              shifts.times { @asm.lsr }
              @asm.sta(at_place(at))
              @asm.note_accumulator_holds(at)
            end
            @asm.note_x_holds([at, links.stride])
            emit_walk_link_read(links, @lists.fetch(walk.links)[2], ahead, last, shifts)
            section = @asm
            y_changes = @asm.y_changes
            with_scaled_current(walk.at, current) { body.each { |child| statement(child) } }
            counted_in_y = counter && section.equal?(@asm) && @asm.y_changes == y_changes
            counted_in_y ? @asm.iny : @asm.inc(at_place(index))
            @asm.jump(top)
            @asm.label(done)
            emit_current_unscaled(current, at, shifts) if current
            store_number(place_of(walk.ahead), DSL::Pool::NONE)
            counted_in_y ? emit_walk_turns_from_y(index, folded(node.count)) : emit_walk_index_kept_below(index, folded(node.count))
          end

          # The walk's turns counted in Y. The repeat's index is a variable, and counting it there is
          # an INC of memory each turn, eight cycles at sixteen bits, where an INY is two (the cycle
          # counts in fullsnes and the SNESdev wiki's 65816 reference). Y is set before the walk and the index written from it once, as the walk ends.
          # Whether Y keeps it through the body is known only once the body is written
          # (W65816#y_changes): where something in it changes Y, the turn counts in memory instead,
          # and the LDY before the walk is left unread.
          #
          # Only where nothing in the body reads the index, which is in memory only as the walk ends,
          # and nothing in it is the game's own instructions or stops the game, past which the index
          # is not written.
          def turns_countable_in_y?(node, body)
            nodes = body.flat_map { |child| child.walk.to_a }
            nodes.none? { |each| %i[raw halt].include?(each.kind) || each.attrs.values.flatten.include?(node.index) }
          end

          # The repeat's index from Y as the tree leaves it: the turns taken, or one below the count
          # where the walk took every one of them.
          def emit_walk_turns_from_y(index, count)
            kept = fresh("walk_counted")
            @asm.cpy(count)
            @asm.bne(kept)
            @asm.dey
            @asm.label(kept, join: true)
            @asm.sty(at_place(index))
          end

          # The thing a walk is on, kept only as X holds it. Each turn of #emit_stepped_walk loads the
          # thing's place, the slot times the stride, into X, and the slot itself is worked out of
          # it by halving and written to the walk's variable for the body to read. Where the body
          # reads that variable only as the index of a slot of the pool's lists, or to compare it with
          # another thing of the pool held still through the walk (`other.index != e.index`), the
          # halving and the write are dropped: X is stored as it is, a slot reached again from that,
          # the other thing scaled once before the walk and compared with X; and the variable is
          # written once, as the walk ends.
          #
          # +scaled+ is where X is stored each turn, +stride+ the pool's, and +partners+ the other
          # things compared with it, by their variables, each with where its scaled place is kept.
          ScaledCurrent = Data.define(:at, :scaled, :stride, :partners)

          # The ScaledCurrent for +walk+ whose +body+ reads its variable (at +at+) only so, or nil.
          def scaled_current(walk, body, at, stride)
            partners = []
            nodes = body.flat_map { |child| child.walk.to_a }
            return if nodes.any? { |each| each.callees.any? || names?(each, walk.at, :var_ref) }

            nodes.each do |each|
              operands = each.attrs.values.flatten.grep(Node).select { |operand| operand.kind == :var_ref && operand.name == walk.at }
              next if operands.empty?
              return unless slot_index_read?(each, operands, stride)

              partner = compared_partner(each, walk, nodes)
              return unless partner || each.kind != :binop

              partners << partner if partner
            end
            ScaledCurrent.new(at: at, scaled: place_of(keep_local(:walk_at_scaled, every_turn: true)), stride: stride,
                              partners: partners.uniq.to_h { |name| [name, place_of(keep_local(:walk_partner_scaled, every_turn: true))] })
          end

          # Whether +node+ reads +operands+, the walk's variable, only as the index of a slot of a list
          # kept at +stride+ and known to be inside, or as one side of an equality compare.
          def slot_index_read?(node, operands, stride)
            return %i[== !=].include?(node.op) && operands.length == 1 if node.kind == :binop
            return false unless %i[list_get list_set].include?(node.kind) && operands == [node.index]

            strided_list?(node.name) && list_slots(node.name).stride == stride && index_inside_full_list?(node.name, node.index)
          end

          # For a compare +node+ of the walk's variable with another variable, that variable's name:
          # one holding a slot of the same pool or NONE, never written in the walk's +nodes+. Nil
          # for any other compare.
          def compared_partner(node, walk, nodes)
            return unless node.kind == :binop

            other = [node.lhs, node.rhs].find { |side| !(side.is_a?(Node) && side.kind == :var_ref && side.name == walk.at) }
            name = variable_named(other)
            return unless name && DSL::Pool.walked_by(name).to_s == walk.pool.to_s && !@scaled_currents&.key?(name)
            return if nodes.any? { |each| names?(each, name, :var_ref) }

            name
          end

          # Runs the block with +current+ (a ScaledCurrent, or nil) known as how the walk's variable
          # +name+ is held.
          def with_scaled_current(name, current)
            outer = @scaled_currents
            @scaled_currents = current ? (outer || {}).merge(name => current) : outer
            yield
          ensure
            @scaled_currents = outer
          end

          # The ScaledCurrent whose slot X is set from for +key+ (#slot_key), or nil.
          def scaled_current_for(key)
            @scaled_currents&.each_value&.find { |current| [current.at, current.stride] == key }
          end

          # The walk's variable as the tree leaves it, from the place last stored: the slot it was on,
          # or as it was where the walk took no turn.
          def emit_current_unscaled(current, at, shifts)
            untouched = fresh("walk_untouched")
            @asm.lda(at_place(current.scaled))
            @asm.bmi(untouched)
            shifts.times { @asm.lsr }
            @asm.sta(at_place(at))
            @asm.label(untouched, join: true)
          end

          # The variable at +from+, a slot or NONE, into the word at +to+ as the slot times the stride
          # (+shifts+ doublings); NONE, whose low half is $FFFF, as it is.
          def emit_slot_scaled(from, to, shifts)
            kept = fresh("walk_none")
            @asm.lda(at_place(from))
            @asm.bmi(kept)
            shifts.times { @asm.asl }
            @asm.label(kept, join: true)
            @asm.sta(at_place(to))
          end

          # The next thing (+ahead+): NONE once the thing at X is the last, else its link, scaled.
          # Without +last+, the link alone, which is NONE at the last thing.
          def emit_walk_link_read(links, width, ahead, last, shifts)
            none = fresh("walk_link_none")
            stepped = fresh("walk_stepped")
            if links.scale == links.stride && last.nil?
              @asm.lda(@asm.long_x(links.base))
              return @asm.sta(at_place(ahead))
            end

            if last
              @asm.cpx(at_place(last))
              @asm.beq(none)
            end
            if links.scale == links.stride
              # Kept as the slot times the stride already, NONE as $FFFF: the next thing as it is.
              @asm.lda(@asm.long_x(links.base))
              @asm.bra(stepped)
              @asm.label(none, join: true)
              @asm.lda(0xFFFF)
              @asm.label(stepped, join: true)
              return @asm.sta(at_place(ahead))
            end

            @asm.lda(@asm.long_x(links.base))
            @asm.and_a(0x00FF) if width == 1
            @asm.cmp(width == 1 ? 0x00FF : 0xFFFF)
            @asm.beq(none)
            shifts.times { @asm.asl }
            @asm.bra(stepped)
            @asm.label(none, join: true)
            @asm.lda(0xFFFF)
            @asm.label(stepped, join: true)
            @asm.sta(at_place(ahead))
          end

          # The repeat's index as the tree leaves it: the turns taken, or one below the count where
          # the walk took every one of them.
          def emit_walk_index_kept_below(index, count)
            kept = fresh("walk_counted")
            @asm.lda(at_place(index))
            @asm.cmp(count)
            @asm.bne(kept)
            @asm.dec(at_place(index))
            @asm.label(kept, join: true)
          end

          # Whether +node+ reads a slot of a list where it is, kept as the tree holds it: the reads the
          # quick ways of this lowering take. A slot kept multiplied is read by #emit_scaled_slot_read.
          def plain_slot_read?(node)
            node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name) &&
              !list_slots(node).scaled?
          end

          # A link kept as the slot times the stride read as the tree holds it, into R0: NONE, kept as
          # $FFFF, as -1; any other, halved back to the slot.
          def emit_scaled_slot_read(node)
            slots = list_slots(node)
            none = fresh("link_none")
            done = fresh("link_read")
            slot = fixed_slot_address(node)
            unless slot
              emit_slot_into_x(slots.header, slots.stride, index_halves(node.index),
                               checked: !index_inside_full_list?(node.name, node.index))
            end
            @asm.lda(slot ? @asm.long(slot) : @asm.long_x(slots.base))
            @asm.cmp(0xFFFF)
            @asm.beq(none)
            slots.scale_shifts.times { @asm.lsr }
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
            @asm.bra(done)
            @asm.label(none, join: true)
            @asm.sta(@asm.direct(R0))
            @asm.sta(@asm.direct(R0 + 2))
            @asm.label(done, join: true)
          end

          # A slot or NONE written into a link kept as the slot times the stride: the index worked
          # out, then the value, as the tree takes them; NONE kept as $FFFF, a slot doubled up.
          def emit_scaled_slot_write(node)
            slots = list_slots(node)
            stored = fresh("link_stored")
            checked = !index_inside_full_list?(node.name, node.index)
            slot = fixed_slot_address(node)
            index = index_in_place(node.index)
            if slot || index
              value(node.value)
              emit_slot_into_x(slots.header, slots.stride, index, checked: checked) unless slot
            else
              push_value(node.index)
              value(node.value)
              pull_into(R1)
              emit_slot_into_x(slots.header, slots.stride, [@asm.direct(R1), @asm.direct(R1 + 2)], checked: checked)
            end
            @asm.lda(@asm.direct(R0))
            @asm.bmi(stored)
            slots.scale_shifts.times { @asm.asl }
            @asm.label(stored, join: true)
            @asm.sta(slot ? @asm.long(slot) : @asm.long_x(slots.base))
          end

          def list_slots(node)
            name = node.is_a?(Symbol) ? node : node.name
            @list_slots.fetch(name) { raise LoweringError, "the list #{name.inspect} is used and never declared" }
          end

          # An index that cannot fall outside its list. A list made full and never made longer or
          # shorter holds its capacity for good, so a number written in the program below that
          # capacity is always inside it: a pool's sprite reading its place in the order, a draw
          # order setting the number of each of its things. And a pool knows its slots are in its
          # lists: a field of the thing a walk is on, read or written in `pool.each` or in a routine
          # of the pool, is a list of the pool's own at a variable the pool keeps a slot in
          # (DSL::Pool::SLOT_PARTS), each made full when the game starts. So the test that the
          # index is inside the list, five instructions on every read, can never fail there and is
          # left out. So is it where the index is known to stay below the capacity from how it is
          # written: a loop's variable, a mask or a remainder (ControlFlow#index_known_below). Every
          # other list read or write keeps it: one ever made longer or shorter, any other index
          # worked out, or another pool's slot.
          def index_inside_full_list?(list, index)
            capacity = full_length_lists[list]
            return false unless capacity

            number = folded(index)
            return number.between?(0, capacity - 1) if number

            below = index_known_below(index)
            return true if below && below <= capacity

            pool = DSL::Pool.owner_of_list(list)
            var = variable_named(index)
            !pool.nil? && !var.nil? && DSL::Pool.walked_by(var) == pool
          end

          # The lists made full of one number and never made longer or shorter after, so each holds
          # its capacity for good, by name, with that capacity (the least, if made twice). Only one
          # made before anything can read or write it (LoweringPlan#lists_made_before_use): until it
          # is made it holds nothing, and a read there stops the game.
          def full_length_lists
            @full_length_lists ||= begin
              resized = @reachable.filter_map do |node|
                node.name if %i[list_push list_drop list_fill list_copy save_load_list].include?(node.kind) ||
                             (node.kind == :list_new && !node.full_of)
              end
              first = @plan.lists_made_before_use
              made = @reachable.select do |node|
                node.kind == :list_new && node.full_of && !resized.include?(node.name) && first.include?(node.name)
              end
              made.group_by(&:name).transform_values { |nodes| nodes.map(&:capacity).min }
            end
          end

          # The length of a list that always holds its capacity (#full_length_lists), by the place of
          # its header, for an index compared with it as a number written in the instruction. That is
          # three bytes read from the cartridge where the length kept in the header is a long address
          # and two bytes read from work RAM, which the console reads at its slower speed (fullsnes,
          # "SNES Memory Map": WRAM is always 2.68MHz). Nil for any other list.
          def full_length_at(place)
            @full_lengths_by_place ||= full_length_lists.each_with_object({}) do |(name, capacity), by_place|
              header, = @lists[name]
              by_place[header] = capacity if header && capacity <= 0xFFFF
            end
            @full_lengths_by_place[place]
          end

          # X at how far into its slots the item the number in +index+ (its two halves) names is. An
          # index outside the list is handed to the runtime, in R0 or R1, which stops the game in the
          # interpreter's words and never returns. Without +checked+, the index is known to be inside
          # (#index_inside_full_list?).
          def emit_slot_into_x(place, width, index, checked: true)
            unless checked
              key = slot_key(index[0], width)
              return if key && @asm.x_holds == key

              if key && (current = scaled_current_for(key))
                @asm.ldx(at_place(current.scaled))
                return @asm.note_x_holds(key)
              end

              emit_low_half_load(index[0])
              (width - 1).bit_length.times { @asm.asl }
              @asm.tax
              return @asm.note_x_holds(key) if key

              return
            end

            inside = fresh("inside_the_list")
            out = fresh("outside_the_list")
            if index[1]
              @asm.lda(index[1])
              @asm.bne(out)
              @asm.lda(index[0])
            else
              # A variable kept in two bytes: below nought is outside the list.
              @asm.lda(index[0])
              @asm.bmi(out)
            end
            full = full_length_at(place)
            @asm.cmp(full || @asm.long(place, Runtime::Lists::LENGTH))
            @asm.bcc(inside)
            @asm.label(out)
            outside = index.first == @asm.direct(R0) ? "rt_list_outside_from_r0" : "rt_list_outside"
            if index[1].nil?
              @asm.lda(index[0])
              @asm.sta(@asm.direct(R1))
              emit_sign_of_a
              @asm.sta(@asm.direct(R1 + 2))
            elsif ![@asm.direct(R0), @asm.direct(R1)].include?(index.first)
              2.times do |half|
                @asm.lda(index[half])
                @asm.sta(@asm.direct(R1 + (2 * half)))
              end
            end
            @asm.ldx(place & 0xFFFF)
            @asm.ldy(place >> 16)
            call_routine(outside)
            @asm.label(inside)
            (width - 1).bit_length.times { @asm.asl }
            @asm.tax
          end

          # X at how far into its slots the item the read +node+ names is (#emit_slot_into_x). An
          # index worked out and known inside the list (#index_inside_full_list?) has only its low
          # half worked out (#emit_low_half), which is all X takes: `row[(t + 3) & 31]` is an add and
          # an AND of one half, where the whole number is both halves stored and read back.
          def emit_slot_of_index_into_x(place, stride, node)
            inside = index_inside_full_list?(node.name, node.index)
            unless inside && index_in_place(node.index).nil?
              return emit_slot_into_x(place, stride, index_halves(node.index), checked: !inside)
            end

            emit_low_half(node.index, 16)
            (stride - 1).bit_length.times { @asm.asl }
            @asm.tax
          end

          # What X holds when a slot is read at it: the low half of the variable +index+ (a place in
          # memory) times +width+, as an assembler's note (W65816#x_holds). Two reads of one slot, or of
          # slots as wide in two lists, one after the other, need X set once: a pool's walk reads the
          # thing's link and whether it is live from two lists of bytes at the slot it is on. Nil for
          # an index the note cannot name.
          def slot_key(index, width)
            return unless index.is_a?(W65816::Operand) && %i[dp abs].include?(index.mode) && index.value.is_a?(Integer)

            [index.value + index.plus, width]
          end

          # R0 = the slot at +slots+ plus X. A slot narrower than a word reads back with its top bit
          # as the sign (Reference::ListValue#wrap_to_width).
          # With +unsigned+, a half-word slot is read back with no sign: its high half nought.
          def emit_read_slot_at_x(slots, width, x: true, unsigned: false)
            if width == 4
              @asm.lda(slot_operand(slots, 2, x))
              @asm.sta(@asm.direct(R0 + 2))
              @asm.lda(slot_operand(slots, 0, x))
              return @asm.sta(@asm.direct(R0))
            end

            read = fresh("slot_read")
            @asm.stz(@asm.direct(R0 + 2))
            @asm.lda(slot_operand(slots, 0, x))
            return @asm.sta(@asm.direct(R0)) if unsigned
            if width == 1
              @asm.and_a(0x00FF)
              @asm.cmp(0x0080)
              @asm.bcc(read)
              @asm.ora(0xFF00)
            else
              @asm.bpl(read)
            end
            @asm.dec(@asm.direct(R0 + 2))
            @asm.label(read)
            @asm.sta(@asm.direct(R0))
          end

          def emit_write_slot_at_x(slots, width, halves, x: true)
            @asm.lda(halves.first)
            if width == 1
              @asm.sep(0x20)
              @asm.sta(slot_operand(slots, 0, x))
              return @asm.rep(0x20)
            end

            @asm.sta(slot_operand(slots, 0, x))
            return unless width == 4

            @asm.lda(halves.last)
            @asm.sta(slot_operand(slots, 2, x))
          end

          # A number going into a byte or half slot keeps only the slot's low bits
          # (Reference::ListValue#wrap_to_width), and the low bits of a sum, a difference or a bit
          # operation come from the low bits of its two sides alone. So such a number made of those,
          # of slots, variables and numbers written in the program, is worked out in its low half
          # only: the high half is work whose answer the slot throws away. The console's own games
          # keep such fields in 8- or 16-bit memory and work them that way. Any other number is
          # worked out whole. R0's low half holds the number to store; its high half is not written.
          def slot_value(node, width)
            return value(node) if width == 4 || folded(node) || !(sum_in_halves?(node) || narrow_slot_read?(node))

            emit_low_half(node, width == 1 ? 8 : 16)
            @asm.sta(@asm.direct(R0))
          end

          # The deepest a sum is worked out a half at a time by #emit_low_half; deeper, it is worked
          # out whole.
          MOST_LOW_HALF_DEPTH = 4

          def narrow_slot_read?(node)
            plain_slot_read?(node) && list_placed(node)[2] < 4
          end

          # A = the low +bits+ (8 or 16) of +node+'s number, the bits above them anything when +bits+
          # is 8. The sides of a sum are worked out in the interpreter's order, the left first.
          def emit_low_half(node, bits, depth = 0)
            if (operand = low_half_operand(node, bits))
              return @asm.lda(operand)
            end
            return emit_low_half_of_slot(node, bits) if node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name)
            return if depth < MOST_LOW_HALF_DEPTH && emit_low_half_of_narrow_step(node, bits, depth)

            unless sum_in_halves?(node) && depth < MOST_LOW_HALF_DEPTH
              value(node)
              return @asm.lda(@asm.direct(R0))
            end

            if (right = low_half_operand(node.rhs, bits))
              emit_low_half(node.lhs, bits, depth + 1)
              emit_carry_for(node.op)
              return emit_half_sum(node.op, right)
            end

            # The left side kept on the stack while the right is worked out; a subtraction is then
            # the left plus the right turned round, plus one.
            emit_low_half(node.lhs, bits, depth + 1)
            @asm.pha
            emit_low_half(node.rhs, bits, depth + 1)
            if node.op == :-
              @asm.eor(0xFFFF)
              @asm.sec
              @asm.adc(@asm.stack(1))
            else
              emit_carry_for(node.op)
              emit_half_sum(node.op, @asm.stack(1))
            end
            @asm.ply # the left side off the stack, A kept
          end

          # Where +node+'s low half can be read from as it is: a number written in the program, a
          # variable, or a slot at a place known here. A byte slot's word holds the next slot's byte
          # above it, so it is such a place only where the bits above the low eight do not matter.
          def low_half_operand(node, bits)
            known = folded(node)
            return @asm.imm(known & 0xFFFF) if known

            if (var = variable_named(node))
              return low_half_of(var)
            end
            return unless plain_slot_read?(node)

            _place, _capacity, width = list_placed(node)
            slot = (width > 1 || bits == 8) && fixed_slot_address(node)
            @asm.long(slot) if slot
          end

          # A = the low +bits+ of a slot read at its index, a byte slot's sign carried into the high
          # byte where all sixteen are wanted.
          def emit_low_half_of_slot(node, bits)
            place, _capacity, width = list_placed(node)
            emit_slot_of_index_into_x(place, list_slots(node).stride, node)
            @asm.lda(@asm.long_x(list_slots(node).base))
            return unless width == 1 && bits == 16

            positive = fresh("byte_positive")
            @asm.and_a(0x00FF)
            @asm.cmp(0x0080)
            @asm.bcc(positive)
            @asm.ora(0xFF00)
            @asm.label(positive)
          end

          # A = the low +bits+ of a negative, a size or a shift by a number written in the program,
          # worked from the low half of what it is made of: true when it was done so.
          #
          # The low half of a negative, and of a shift up, come from the low half alone, whatever the
          # number. A size (`abs`) and a shift down need the bits above too, unless the number is
          # proven to stay in 16 bits (NumberRanges), when those bits are only its sign: then the
          # 16-bit accumulator does it, a shift down by 4 four LSRs of a number never below nought,
          # where the two halves of a whole number take three instructions a place.
          def emit_low_half_of_narrow_step(node, bits, depth)
            return false unless node.is_a?(Node)

            case node.kind
            when :neg
              emit_low_half(node.operand, bits, depth + 1)
              emit_negate_a
              true
            when :absolute then emit_low_half_of_size(node.operand, depth)
            when :table_get then emit_low_half_of_entry(node, bits, depth)
            when :shift_right then emit_low_half_shifted_down(node.operand, node.bits, depth)
            when :binop
              count = folded(node.rhs)
              return false unless count && %i[<< >>].include?(node.op)
              return emit_low_half_shifted_down(node.lhs, count, depth) if node.op == :>>

              emit_low_half_shifted_up(node.lhs, count, bits, depth)
            else false
            end
          end

          # A = the low +bits+ of a table's entry, for a table of bytes or halves in one part: the
          # entry read at X with no whole number made of it, a byte's sign carried into the high
          # byte where all sixteen are wanted (#value_of_table_get makes the whole number).
          def emit_low_half_of_entry(node, bits, depth)
            table = @tables[node.name] or return false
            bytes, signed = table_keeping(table)
            return false if bytes == 4 || split?(table)

            emit_low_half(LoweringPlan.index_kept_in_range(node.index, table.values.length), 16, depth + 1)
            @asm.asl if bytes == 2
            @asm.tax
            @asm.lda(@asm.long_x(table_label(table.name)))
            return true unless bytes == 1 && bits == 16

            @asm.and_a(0x00FF)
            return true unless signed

            positive = fresh("entry_positive")
            @asm.cmp(0x0080)
            @asm.bcc(positive)
            @asm.ora(0xFF00)
            @asm.label(positive)
            true
          end

          # A = A turned round: every bit flipped and one added.
          def emit_negate_a
            @asm.eor(0xFFFF)
            @asm.inc(:a)
          end

          # A = the size of +operand+'s number, where it stays in 16 bits. The most negative such,
          # -32768, has the size 32768, whose low half is $8000, which is what turning $8000 round
          # gives.
          def emit_low_half_of_size(operand, depth)
            return false unless within_half?(proven_range(operand))

            positive = fresh("positive")
            emit_low_half(operand, 16, depth + 1)
            @asm.cmp(0x8000) # the carry is set when the number is below nought
            @asm.bcc(positive)
            emit_negate_a
            @asm.label(positive)
            true
          end

          def emit_low_half_shifted_up(operand, count, bits, depth)
            if count.negative? || count >= 16
              @asm.lda(0)
              return true
            end

            emit_low_half(operand, bits, depth + 1)
            count.times { @asm.asl }
            true
          end

          # A shift down of a number that stays in 16 bits: LSR when it is never below nought, and
          # otherwise the sign carried in from the top (CMP $8000 sets the carry for a number below
          # nought) as each place is rotated in. Fifteen places or more leave only the sign.
          def emit_low_half_shifted_down(operand, count, depth)
            range = proven_range(operand)
            return false unless within_half?(range) && Int32.shift_count_in_range?(count)
            if range.begin >= 0 && count >= 16
              @asm.lda(0)
              return true
            end

            emit_low_half(operand, 16, depth + 1)
            if range.begin >= 0
              count.times { @asm.lsr }
            else
              [count, 15].min.times do
                @asm.cmp(0x8000)
                @asm.ror
              end
            end
            true
          end

          # A list put in order, written in place (Reference#exec_list_sort): an insertion sort over
          # the slots, which are where they are for good (a list nothing takes from the front keeps
          # its first item in its first slot), so both lists are reached with their own addresses.
          # Each item is taken in turn and moved back past every item before it whose number is
          # strictly beyond its own, so level items keep their order, and a list already in order
          # costs one compare an item. The console's own games put their sprites in order by height
          # every frame the same way, in about ten instructions a sprite.
          #
          # Y is how far into the list's slots the item taken is, and two pointers on the direct page
          # reach the slot there and the slot before it, so a step back is a load and a store with
          # Y; X is how far into +by+'s slots an item's number is, so it is compared where it lies.
          # A half or a byte number fits in 16 bits once its sign is spread, so it is kept and
          # compared as 16 bits.
          #
          # The number of the item in the slot before the one taken is kept in R0, so the first
          # compare of each item, the only one when nothing passed anything, reads nothing but the
          # item's own number. It stays true either way: an item that stays is the slot's now, and
          # one that moves back moves the item that was before it into its slot. An item that stays
          # is the whole of that path: its number into R0, Y on to the next. Everything a move needs
          # is set up only when one is, out of the way after the loop.
          #
          #   R0  the number of the item in the slot before    R1  how far in the item that moves
          #   R2  the item that moves, as its slot holds it        is, and (high half) the list's end
          #   R3  its number    R4  pointer to the slot before Y's    R5  pointer to Y's slot
          def emit_list_sort(node)
            keyed = @keyed_sorts&.fetch(node.name, nil)
            return emit_keyed_sort_asked(node, keyed) if keyed

            refuse_ring_sort!(node)
            place, _capacity, width = list_placed(node)
            keys_place, _keys_capacity, key_width = @lists.fetch(node.by) do
              raise LoweringError, "the list #{node.by.inspect} is sorted by and never declared"
            end
            sort = SortPlaces.new(slots: list_slots(node).base, width: width,
                                  keys: keys_place + Runtime::Lists::HEADER, key_width: key_width,
                                  descending: node.descending)
            next_item = fresh("sort_item")
            moves = fresh("sort_moves")
            step_back = fresh("sort_step")
            placed = fresh("sort_placed")
            advance = fresh("sort_next")
            done = fresh("sort_done")

            @asm.lda(@asm.long(place, Runtime::Lists::LENGTH))
            @asm.cmp(2)
            @asm.branch_long(:bcc, done) # one item or none is in order already
            (width - 1).bit_length.times { @asm.asl }
            @asm.sta(@asm.direct(SORT_SPAN + 2))
            { SORT_BEFORE => sort.slots - width, SORT_AT => sort.slots }.each do |pointer, address|
              @asm.lda(address & 0xFFFF)
              @asm.sta(@asm.direct(pointer))
              @asm.lda(address >> 16)
              @asm.sta(@asm.direct(pointer + 2))
            end
            @asm.lda(@asm.long(sort.slots))
            emit_sort_key_offset_into_x(sort)
            emit_sort_key_copy(emit_sort_key_at_x(sort), R0)
            @asm.ldy(width)

            # Each item: stays, or moves.
            @asm.label(next_item)
            @asm.lda(@asm.ind_long_y(SORT_AT))
            emit_sort_key_offset_into_x(sort)
            key = emit_sort_key_at_x(sort)
            emit_sort_compare(sort, sort.halves(@asm, R0), key)
            @asm.bmi(moves)
            emit_sort_key_copy(key, R0)
            @asm.label(advance)
            width.times { @asm.iny }
            @asm.cpy(@asm.direct(SORT_SPAN + 2))
            @asm.bcc(next_item)
            @asm.brl(done)

            # An item that moves: taken, and every item before it whose number is beyond its own
            # moved up a slot, the first of them the one already compared.
            @asm.label(moves)
            @asm.sty(@asm.direct(SORT_SPAN))
            emit_sort_key_copy(key, SORT_KEY)
            @asm.lda(@asm.ind_long_y(SORT_AT))
            @asm.sta(@asm.direct(SORT_ITEM))
            if width == 4
              2.times { @asm.iny }
              @asm.lda(@asm.ind_long_y(SORT_AT))
              @asm.sta(@asm.direct(SORT_ITEM + 2))
              2.times { @asm.dey }
            end
            emit_sort_slot_move_up(width)
            width.times { @asm.dey }
            @asm.beq(placed)
            @asm.label(step_back)
            @asm.lda(@asm.ind_long_y(SORT_BEFORE))
            emit_sort_key_offset_into_x(sort)
            emit_sort_compare(sort, emit_sort_key_at_x(sort), sort.halves(@asm, SORT_KEY))
            @asm.bpl(placed)
            emit_sort_slot_move_up(width)
            width.times { @asm.dey }
            @asm.bne(step_back)
            @asm.label(placed)
            @asm.lda(@asm.direct(SORT_ITEM))
            emit_sort_slot_write(width)
            @asm.ldy(@asm.direct(SORT_SPAN))
            @asm.brl(advance)
            @asm.label(done)
          end

          # Where the sort keeps what it works with, on the direct page (#emit_list_sort).
          SORT_SPAN = Memory.register(1)
          SORT_ITEM = Memory.register(2)
          SORT_KEY = Memory.register(3)
          SORT_BEFORE = Memory.register(4)
          SORT_AT = Memory.register(5)
          SORT_SPREAD = Memory.register(6)

          # One list_sort's two lists: where each one's slots start and how wide a slot is, and which
          # way round. +halves+ is where a number kept on the direct page at +at+ is, as operands: one
          # 16-bit half, or two for a word.
          SortPlaces = Data.define(:slots, :width, :keys, :key_width, :descending) do
            def halves(asm, at) = key_width == 4 ? [asm.direct(at), asm.direct(at + 2)] : [asm.direct(at)]
          end

          # X = how far into +by+'s slots the number of the item in A is: a byte slot's item is its
          # low byte alone.
          def emit_sort_key_offset_into_x(sort)
            @asm.and_a(0x00FF) if sort.width == 1
            (sort.key_width - 1).bit_length.times { @asm.asl }
            @asm.tax
          end

          # The number +by+ holds at X, as the operands it can be read from: where it lies, for a
          # half or a word, or the direct page once a byte's sign is spread through 16 bits.
          def emit_sort_key_at_x(sort)
            case sort.key_width
            when 4 then [@asm.long_x(sort.keys), @asm.long_x(sort.keys, 2)]
            when 2 then [@asm.long_x(sort.keys)]
            else
              @asm.lda(@asm.long_x(sort.keys))
              emit_byte_sign_spread
              @asm.sta(@asm.direct(SORT_SPREAD))
              [@asm.direct(SORT_SPREAD)]
            end
          end

          # The number at +halves+ kept on the direct page at +at+.
          def emit_sort_key_copy(halves, at)
            halves.each_with_index do |half, i|
              @asm.lda(half)
              @asm.sta(@asm.direct(at + (2 * i)))
            end
          end

          # A's low byte as a signed number in all 16 bits: flipping the top bit and taking it away
          # again carries the sign up.
          def emit_byte_sign_spread
            @asm.and_a(0x00FF)
            @asm.eor(0x0080)
            @asm.sec
            @asm.sbc(0x0080)
          end

          # N set when the number at +before+ (its halves) is strictly beyond the one at +key+: above
          # it, or below it when the sort is descending, so the item whose number is +key+ moves back
          # past it. The one taken from the other is signed, so its sign is the answer once an
          # overflow (V) has turned it round.
          def emit_sort_compare(sort, before, key)
            first, second = sort.descending ? [before, key] : [key, before]
            signed = fresh("sort_signed")
            @asm.lda(first[0])
            @asm.sec
            @asm.sbc(second[0])
            if sort.key_width == 4
              @asm.lda(first[1])
              @asm.sbc(second[1])
            end
            @asm.bvc(signed)
            @asm.eor(0x8000)
            @asm.label(signed)
          end

          # The slot before Y's copied into Y's, as many bytes as a slot takes.
          def emit_sort_slot_move_up(width)
            @asm.lda(@asm.ind_long_y(SORT_BEFORE))
            return emit_sort_byte_store if width == 1

            @asm.sta(@asm.ind_long_y(SORT_AT))
            return unless width == 4

            2.times { @asm.iny }
            @asm.lda(@asm.ind_long_y(SORT_BEFORE))
            @asm.sta(@asm.ind_long_y(SORT_AT))
            2.times { @asm.dey }
          end

          # A (the item's low half) into Y's slot, and its high half after it for a word.
          def emit_sort_slot_write(width)
            return emit_sort_byte_store if width == 1

            @asm.sta(@asm.ind_long_y(SORT_AT))
            return unless width == 4

            2.times { @asm.iny }
            @asm.lda(@asm.direct(SORT_ITEM + 2))
            @asm.sta(@asm.ind_long_y(SORT_AT))
          end

          def emit_sort_byte_store
            @asm.sep(0x20)
            @asm.sta(@asm.ind_long_y(SORT_AT))
            @asm.rep(0x20)
          end

          # A sort whose numbers are kept by place in the order, the way a draw order's is
          # (Builder::DrawOrder#order_sort_nodes): every frame its routine works out one number for
          # each thing, by the thing's place in the run, and sorts the order by them.
          #
          # The sort above reaches an item's number through the item, so each compare is first a read
          # of the order and a sum for where the number is, and then a copy of that number for the
          # next compare: nineteen instructions a thing on a frame where nobody passed anybody. Here each
          # number is kept in the place in the order its thing is in, not by the thing. A thing's
          # number is written there as it is worked out, through one index read from a table of where
          # each thing is, and the sort then compares each place's number with the one before it at
          # addresses known as the cartridge is built: four loads and a branch, written out once for
          # each place, six instructions a thing. An item that does move swaps with the one
          # before it there and then, also written out for each place, since two things passing is
          # nearly every move; one that goes further goes on to one routine that moves it back as the
          # sort above does, its number and its item with it.
          #
          # What is left is mostly the numbers themselves, written as whole words: five instructions
          # a thing for a number that is a copy of its place (Builder::DrawOrder#without_common_addend
          # leaves out an amount every thing adds), eight for a sum, the index read among them.
          #
          # The order is kept in these tables, not in the list. Three tables in the first 8K, where a
          # 16-bit address reaches them: the numbers, by place, low halves and high halves apart;
          # where each item is, as twice its place, by item; and each place's item doubled, by place, which is
          # what the sprites are placed from (Picture#emit_ordered_run), so placing an ordered sprite
          # is a load and a jump. The two lists the IR names are the framework's own, nothing else
          # reads them (LoweringPlan#sorts_kept_apart holds to that), and nothing compares them with the
          # interpreter's, so the numbers list is not written and the order list keeps the order the
          # game started in. What is drawn is the interpreter's order, and that is what is checked.
          # A sort is kept this way only in the first 8K's room for its tables.
          #
          # Every table is two bytes a place, the numbers' low halves and high halves kept apart, so
          # one index reaches a place's number and its item, and an item doubled is where it is in the
          # table of places: two times its place.
          #
          # The tables as the direct page, for a sort written where it is called
          # (#sort_written_in_place?) whose numbers are each read where they are. The direct page is
          # the 256 bytes an instruction names with one byte rather than two, a fetch from the
          # cartridge fewer, and the processor's D register says where it starts. Moved to the page
          # the tables start in while their numbers are written and sorted, every read and write of
          # them is that fetch quicker; D is put back to the game's page, $0000, after. It must start
          # a page (its low byte nought), or each of those instructions takes a step more and the
          # fetch saved is spent again. +page+ is where D goes, nil for a sort that keeps D where it
          # is, and +scratch+ the six bytes that sort's moving routine keeps an item and its number
          # in, since the game's working numbers are not on the page then.
          KeyedSort = Data.define(:order, :keys, :count, :lows, :highs, :places, :entries, :descending, :page, :scratch) do
            # The operand for +address+, plus X when +x+: on the direct page when the sort moves D
            # there and the address is within the page's 256 bytes, else by its 16-bit address.
            def at(asm, address, x: false)
              offset = page && (address - page)
              return x ? asm.direct_x(offset) : asm.direct(offset) if offset&.between?(0, 0xFF)

              x ? asm.abs_x(address) : asm.abs(address)
            end

            # The operands for the two halves of the number +plus+ bytes into the numbers (two bytes
            # a place), plus X when +x+.
            def number(asm, plus, x: false) = [lows, highs].map { |table| at(asm, table + plus, x: x) }
          end

          # Which sorts keep their numbers by place (LoweringPlan#sorts_kept_apart, with room in the
          # first 8K for their tables), and where each one's tables are.
          def keep_order_tables
            @keyed_sorts = {}
            @keys_by_place = {}
            @plan.sorts_kept_apart.each_value do |node|
              count = @declared_lists.fetch(node.name).capacity
              next if @memory.near_bytes_left < NEAR_BYTES_LAST + (count * 8)

              said = "the order #{node.name.inspect}"
              keyed = KeyedSort.new(order: node.name, keys: node.by, count: count, descending: node.descending,
                                    lows: @memory.reserve("the numbers of #{said}", count * 2),
                                    highs: @memory.reserve("the numbers' high halves of #{said}", count * 2),
                                    places: @memory.reserve("the places in #{said}", count * 2),
                                    entries: @memory.reserve("the items of #{said}", count * 2), page: nil, scratch: nil)
              @keyed_sorts[node.name] = keyed
              @keys_by_place[node.by] = keyed
            end
            keep_shown_sorts
            @sorts_written_in_place =@called.select { |name| sort_written_in_place?(name) }.freeze
            @sorts_written_in_place.each { |name| keep_sort_on_its_page(@funcs.fetch(name).children) }
          end

          # The sort of +body+ (a routine #sort_written_in_place? holds) given the page its tables
          # start in as its direct page, when every number it writes is read where it is: a number
          # worked out first is worked out in the game's working numbers, which are on the game's
          # own page. A first 8K with no room for the moving routine's six bytes keeps D where it is.
          def keep_sort_on_its_page(body)
            keyed = @keyed_sorts.fetch(body.last.name)
            return unless body[0...-1].all? { |node| key_read_in_place?(without_added_nought(node.value)) }
            return if @memory.near_bytes_left < NEAR_BYTES_LAST + 6

            paged = keyed.with(page: keyed.lows & 0xFF00, scratch: @memory.reserve("the moving number of the order #{keyed.order.inspect}", 6))
            @keyed_sorts[keyed.order] = paged
            @keys_by_place[keyed.keys] = paged
          end

          # Whether #emit_key_by_place writes +value+ with nothing worked out first: a variable, a
          # number written in the program, a word slot at a fixed place, or a sum or difference of
          # two of those. Asked before any routine is written, so the operands it looks for are made
          # in an assembler of their own and thrown away.
          def key_read_in_place?(value)
            kept = @asm
            @asm = measuring_assembler
            return true if key_low_half_in_place?(value)

            read = ->(node) { operand_halves(node) || fixed_word_slot_halves(node) }
            return !!read.call(value) unless sum_in_halves?(value) && %i[+ -].include?(value.op)

            !!(read.call(without_added_nought(value.lhs)) && read.call(value.rhs))
          ensure
            @asm = kept
          end

          # A draw order's routine written where it is called. The routine (Builder::DrawOrder
          # #finalize_draw_orders) is the numbers written by place and the sort, called once
          # before the frame's sprites are placed: a long call and its return are about as much
          # as two places' compares, so where it is called once its statements are written there
          # instead, and the routine is not made. One called from more than one place stays a
          # routine, so its code is not written twice.
          def sort_written_in_place?(name)
            return false if on_chip?(name)

            body = @funcs[name]&.children or return false
            sort = body.last
            return false unless sort&.kind == :list_sort && @keyed_sorts.key?(sort.name)

            keys = @keyed_sorts.fetch(sort.name).keys
            return false unless body[0...-1].all? { |node| node.kind == :list_set && node.name == keys }

            @program.walk.count { |node| node.kind == :call && node.target == name } == 1 &&
              @program.walk.none? { |node| node.kind == :call_one_of && node.targets.include?(name) }
          end

          # The tables as the order starts: item +n+ in place +n+.
          def emit_order_tables_start(keyed)
            keyed.count.times do |item|
              @asm.lda(item * 2)
              @asm.sta(@asm.abs(keyed.places + (item * 2)))
              @asm.sta(@asm.abs(keyed.entries + (item * 2)))
            end
          end

          # A thing's number, written into the slot of the order its thing is in: X from the table of
          # places, then the number into the slot there, a half at a time. For a sort handed +shown+,
          # only where the thing shows, which its things are asked first to know (ShownSort).
          def emit_key_by_place(node, keyed)
            shown = @shown_sorts&.fetch(keyed.order, nil)
            return emit_number_by_place(node, keyed) unless shown

            sort = @shown_sort_nodes.fetch(keyed.order)
            unless @shown_asked == keyed.order
              raise LoweringError, "the things of #{keyed.order.inspect} are asked on the moved direct page" if @direct_page_moved

              emit_shown_asked_once(sort, shown, keyed)
            end
            emit_unless_hidden(shown, folded(node.index)) { emit_number_by_place(node, keyed) }
          end

          def emit_number_by_place(node, keyed)
            place = keyed.at(@asm, keyed.places + (folded(node.index) * 2))
            to = keyed.number(@asm, 0, x: true)
            value = without_added_nought(node.value)
            return emit_key_low_half_by_place(value, place, to) if key_low_half_in_place?(value)

            if sum_in_halves?(value) && %i[+ -].include?(value.op)
              return with_key_halves(without_added_nought(value.lhs), value.rhs) do |lefts, rights|
                @asm.ldx(place)
                emit_carry_for(value.op)
                2.times do |i|
                  @asm.lda(lefts[i])
                  emit_half_sum(value.op, rights[i])
                  @asm.sta(to[i])
                end
              end
            end

            halves = operand_halves(value) || fixed_word_slot_halves(value)
            unless halves
              value(value)
              halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
            end
            @asm.ldx(place)
            2.times do |i|
              @asm.lda(halves[i])
              @asm.sta(to[i])
            end
          end

          # A key proven to stay in 16 BITS (NumberRanges) is worked out in its low half alone: the
          # whole number is that half with its sign spread upward, so the high half is nought for a
          # key never below nought, and otherwise nought or all ones by the sign. A key read from a
          # variable kept in two bytes (HalfVariables) or a list kept in half words
          # (#lists_kept_in_halves) has no high half to read. Worked out whole, it would go through
          # R0, on the game's direct page, and keep the sort from moving D to its tables
          # (#keep_sort_on_its_page). Taken where its low half is read where it is (a variable, a
          # number, a slot at a fixed place, or a sum or difference of two of those) and either
          # nothing whole is, or the high half is nought: one store of nought rather than a load and
          # a store.
          def key_low_half_in_place?(value)
            range = proven_range(value)
            return false unless within_half?(range)

            low = ->(node) { low_half_operand(node, 16) }
            whole = ->(node) { operand_halves(node) || fixed_word_slot_halves(node) }
            if sum_in_halves?(value) && %i[+ -].include?(value.op)
              left = without_added_nought(value.lhs)
              return false unless low.call(left) && low.call(value.rhs)

              range.begin >= 0 || !(whole.call(left) && whole.call(value.rhs))
            else
              return false unless low.call(value)

              range.begin >= 0 || !whole.call(value)
            end
          end

          # The key +value+ (#key_low_half_in_place?) into the numbers at +to+, X from +place+.
          def emit_key_low_half_by_place(value, place, to)
            @asm.ldx(place)
            emit_low_half(value, 16)
            @asm.sta(to[0])
            return @asm.stz(to[1]) if proven_range(value).begin >= 0

            emit_sign_of_a
            @asm.sta(to[1])
          end

          # with_both_halves, also reading a word list's slot at a place written in the program where
          # it is.
          def with_key_halves(left, right, &)
            lefts = operand_halves(left) || fixed_word_slot_halves(left)
            rights = operand_halves(right) || fixed_word_slot_halves(right)
            return yield(lefts, rights) if lefts && rights

            with_both_halves(left, right, slot_at_x: false, &)
          end

          # The sort itself: each place after the first compared with the one before it, and the
          # routine that moves an item back called only for one that has to go.
          #
          # An order that turns round. Moving each item back a place at a time is a step for every
          # pair of things that passed each other, so when every thing passes every other (the
          # whole order turned round, as when everything is flipped top to bottom) a pool of 32 is
          # nearly 500 steps, more than a frame on this processor. So before an item goes back further
          # than one place, the routine that turns a run round (#emit_keyed_run_reversal) looks for
          # a run of things each strictly beyond the next, starting with the pair just swapped, and
          # turns the whole run over at once, half as many swaps as it is long. The sort then
          # takes up again at the place before the run, which the run's first item may still have
          # to go back past. Only a run strictly falling is turned, so two things level never swap
          # and keep the order they had, as the interpreter keeps them (Reference#exec_list_sort).
          # Two things passing, the move nearly every frame makes, never reach the routine except
          # at the first place, which has no place before it to tell the two apart.
          #
          # A sort handed +shown+ (ShownSort) starts at the place after the first thing showing, through
          # a table. The places before it hold the number nothing is strictly beyond, so the compares,
          # the turning of a run and the moving routine stop there with nothing added.
          def emit_keyed_sort(keyed, shown = nil)
            mover = fresh("sort_move")
            reversal = fresh("sort_reverse") if keyed.count > 2
            done = fresh("sort_done")
            starts = (1...keyed.count).to_h { |place| [place, fresh("sort_place")] }
            emit_keyed_start_past_hidden(shown, keyed, starts, done) if shown
            (1...keyed.count).each do |place|
              stays = fresh("sort_stays")
              @asm.label(starts.fetch(place))
              emit_keyed_stays_unless_beyond(keyed, keyed.number(@asm, place * 2), keyed.number(@asm, (place * 2) - 2), stays)
              emit_keyed_swap(keyed, place)
              if place > 1
                emit_keyed_stays_unless_beyond(keyed, keyed.number(@asm, (place * 2) - 2), keyed.number(@asm, (place * 2) - 4), stays)
              end
              if reversal && place < keyed.count - 1
                @asm.ldx(place * 2)
                @asm.jsr(@asm.abs(reversal))
                @asm.branch_long(:bcs, starts.fetch([place - 1, 1].max))
              end
              if place > 1
                @asm.ldx((place - 1) * 2)
                @asm.jsr(@asm.abs(mover))
              end
              @asm.label(stays)
            end
            @asm.brl(done)
            emit_keyed_move(keyed, mover)
            emit_keyed_run_reversal(keyed, reversal) if reversal
            @asm.label(done)
          end

          # The keyed sort of +node+, its things asked first where they were not (ShownSort).
          def emit_keyed_sort_asked(node, keyed)
            shown = @shown_sorts&.fetch(node.name, nil)
            emit_shown_asked_once(node, shown, keyed) if shown
            emit_keyed_sort(keyed, shown)
          ensure
            @shown_asked = nil
          end

          # The routine that turns a run round (#emit_keyed_sort), called with X twice a place whose
          # item and the one before have just been swapped. Carry clear when the item after it is not
          # strictly beyond the swapped item, so there is no run longer than the two, and nothing is
          # done. Otherwise the swap is undone, the run found from the place before to the last place
          # strictly beyond the one before it, every pair of it swapped from the two ends in, and the
          # table of places written again across it; carry set. Its three words are the moving
          # routine's own (#emit_keyed_move), which is never running then: where the run starts, one
          # past where it ends, and the last place not yet swapped (Y), for X to be compared with.
          def emit_keyed_run_reversal(keyed, reversal)
            run = fresh("sort_run")
            scan = fresh("sort_scan")
            scanned = fresh("sort_scanned")
            turn = fresh("sort_turn")
            placing = fresh("sort_placing")
            first, past, last = keyed_scratch_words(keyed)
            @asm.label(reversal)
            emit_keyed_compare(keyed, keyed.number(@asm, 2, x: true), keyed.number(@asm, -2, x: true))
            @asm.bmi(run)
            @asm.clc
            @asm.rts

            @asm.label(run)
            @asm.txy
            2.times { @asm.dex }
            @asm.stx(first)
            emit_keyed_swap_x_and_y(keyed)
            @asm.tyx
            2.times { @asm.inx }
            @asm.label(scan)
            @asm.cpx((keyed.count - 1) * 2)
            @asm.bcs(scanned)
            emit_keyed_compare(keyed, keyed.number(@asm, 2, x: true), keyed.number(@asm, 0, x: true))
            @asm.bpl(scanned)
            2.times { @asm.inx }
            @asm.bra(scan)

            @asm.label(scanned)
            @asm.txy
            2.times { @asm.inx }
            @asm.stx(past)
            @asm.ldx(first)
            @asm.label(turn)
            emit_keyed_swap_x_and_y(keyed)
            2.times { @asm.inx }
            2.times { @asm.dey }
            @asm.sty(last)
            @asm.cpx(last)
            @asm.bcc(turn)

            @asm.ldx(first)
            @asm.label(placing)
            @asm.lda(keyed.at(@asm, keyed.entries, x: true))
            @asm.tay
            @asm.txa
            @asm.sta(@asm.abs_y(keyed.places))
            2.times { @asm.inx }
            @asm.cpx(past)
            @asm.bcc(placing)
            @asm.sec
            @asm.rts
          end

          # The items in the places X and Y name (each twice its place) swapped, their numbers with
          # them. The table of places is left for the caller to write.
          def emit_keyed_swap_x_and_y(keyed)
            [keyed.lows, keyed.highs, keyed.entries].each do |table|
              @asm.lda(keyed.at(@asm, table, x: true))
              @asm.pha
              @asm.lda(@asm.abs_y(table))
              @asm.sta(keyed.at(@asm, table, x: true))
              @asm.pla
              @asm.sta(@asm.abs_y(table))
            end
          end

          # The three words the moving routine keeps an item's number and the item in: the sort's
          # +scratch+ on its own page, or the direct page's.
          def keyed_scratch_words(keyed)
            if keyed.scratch
              [0, 2, 4].map { |plus| keyed.at(@asm, keyed.scratch + plus) }
            else
              [@asm.direct(SORT_KEY), @asm.direct(SORT_KEY + 2), @asm.direct(SORT_ITEM)]
            end
          end

          # A jump to +stays+ unless the number at +item+ (two halves) is strictly beyond the one at
          # +before+; past it when it is, so the item moves. The subtraction overflows only for two
          # numbers far apart, so the branch for a sign that overflowed is the one not taken: a place
          # that stays is a branch not taken and one taken, where turning the sign round first
          # (#emit_keyed_compare) is two taken.
          def emit_keyed_stays_unless_beyond(keyed, item, before, stays)
            overflowed = fresh("sort_overflowed")
            moves = fresh("sort_moves")
            first, second = keyed.descending ? [before, item] : [item, before]
            @asm.lda(first[0])
            @asm.cmp(second[0])
            @asm.lda(first[1])
            @asm.sbc(second[1])
            @asm.bvs(overflowed)
            @asm.bpl(stays)
            @asm.bra(moves)
            @asm.label(overflowed)
            @asm.bmi(stays)
            @asm.label(moves)
          end

          # The item in +place+ and the one before it swapped, at addresses known as the cartridge is
          # built: the step nearly every move is, when two things pass each other. Twenty
          # instructions, about half what the general step takes (#emit_keyed_move).
          def emit_keyed_swap(keyed, place)
            at = place * 2
            [keyed.lows, keyed.highs].each do |table|
              @asm.lda(keyed.at(@asm, table + at))
              @asm.ldy(keyed.at(@asm, table + at - 2))
              @asm.sta(keyed.at(@asm, table + at - 2))
              @asm.sty(keyed.at(@asm, table + at))
            end
            @asm.ldy(keyed.at(@asm, keyed.entries + at))
            @asm.ldx(keyed.at(@asm, keyed.entries + at - 2))
            @asm.sty(keyed.at(@asm, keyed.entries + at - 2))
            @asm.stx(keyed.at(@asm, keyed.entries + at))
            @asm.lda(at - 2)
            @asm.sta(@asm.abs_y(keyed.places)) # no store names the direct page plus Y
            @asm.lda(at)
            @asm.sta(keyed.at(@asm, keyed.places, x: true))
          end

          # N set when the number at +item+ (two halves) is strictly beyond the one at +before+, so the
          # item moves back past it.
          def emit_keyed_compare(keyed, item, before)
            first, second = keyed.descending ? [before, item] : [item, before]
            signed = fresh("sort_signed")
            @asm.lda(first[0])
            @asm.cmp(second[0])
            @asm.lda(first[1])
            @asm.sbc(second[1])
            @asm.bvc(signed)
            @asm.eor(0x8000)
            @asm.label(signed)
          end

          # The item in the place X names (X twice the place) moved back past every item before it
          # whose number is strictly beyond its own, as the sort above moves one: each of those a
          # place on, its number and its item with it, and the table of places told. X is twice the
          # place the item is going to, which reaches that place in every table, and Y the item there
          # (itself twice a place), which reaches the item in the table of places. The first compare
          # is the one that sent the item here, so the first step is taken without it. The sort comes
          # here only for an item that goes back more than one place (#emit_keyed_swap takes the
          # first), and each place it goes back is about twenty instructions.
          #
          #   R2  the item, doubled    R3  its number    (or the sort's +scratch+, for one on its own page)
          def emit_keyed_move(keyed, mover)
            step = fresh("sort_step")
            placed = fresh("sort_placed")
            low, high, item = keyed_scratch_words(keyed)
            key = [low, high]
            here = keyed.number(@asm, 0, x: true)
            before = keyed.number(@asm, -2, x: true)
            @asm.label(mover)
            2.times do |half|
              @asm.lda(here[half])
              @asm.sta(key[half])
            end
            @asm.lda(keyed.at(@asm, keyed.entries, x: true))
            @asm.sta(item)

            @asm.label(step)
            2.times do |half|
              @asm.lda(before[half])
              @asm.sta(here[half])
            end
            @asm.lda(keyed.at(@asm, keyed.entries - 2, x: true))
            emit_item_placed(keyed)
            2.times { @asm.dex }
            @asm.beq(placed)
            emit_keyed_compare(keyed, key, before)
            @asm.bmi(step)

            @asm.label(placed)
            2.times do |half|
              @asm.lda(key[half])
              @asm.sta(here[half])
            end
            @asm.lda(item)
            emit_item_placed(keyed)
            @asm.rts
          end

          # The item doubled in A put in the place X names, in the table of items and the table of
          # places.
          def emit_item_placed(keyed)
            @asm.sta(keyed.at(@asm, keyed.entries, x: true))
            @asm.tay
            @asm.txa
            @asm.sta(@asm.abs_y(keyed.places))
          end

          # A list taken from the front keeps its items round a ring, so its slots are not where the
          # sort reaches them. The framework sorts only lists it made, which nothing takes from.
          def refuse_ring_sort!(node)
            ring = [node.name, node.by].find { |name| front_dropped_lists.include?(name) }
            return unless ring

            raise LoweringError, "the list #{ring.inspect} is put in order and also has items taken from its " \
                                 "front, which the Super Nintendo's sort cannot reach. Sort a list nothing takes from the front."
          end

          # A run of a table's entries copied into a list: the table's place and how it keeps its
          # entries, so the runtime reads them as a run does.
          def emit_list_copy(node)
            held = held_run_of_list(node.name)
            return emit_held_picture_choice(node, held) if held

            table = @tables.fetch(node.table) { raise LoweringError, "the table #{node.table.inspect} is copied and never declared" }
            kept = Runtime::Lists::KEPT.fetch(TABLE_KEPT.fetch(table_keeping(table)))
            return emit_list_copy_from_parts(node, table, kept) if split?(table)

            list_call("rt_list_copy", node, LongAddress.new(table_label(table.name)), Build.int(kept),
                      Build.int(table.values.length), node.at, Build.int(node.count))
          end

          # A run copied from a table cut into parts: its start held inside the table here, as the
          # runtime would, and the runtime handed the part the start is in, which holds the whole
          # run (#table_sections), and where in that part it starts. rt_list_copy takes the list in
          # R0, the table's place in R1 (here the part's, which #emit_part_place leaves there), how
          # it keeps an entry in R2, its length in R3, the start in R4 and the run's length in R5.
          # The length handed is the part's own entries and the run, so the start in the part is
          # never moved by the runtime's own holding.
          def emit_list_copy_from_parts(node, table, kept)
            last_start = [table.values.length - node.count, 0].max
            value(Build.clamped(node.at, Build.int(0), Build.int(last_start)))
            emit_part_place(table)
            start = Memory.register(4)
            @asm.sta(@asm.direct(start))
            @asm.stz(@asm.direct(start + 2))
            numbers = { 0 => list_place(node), 2 => kept, 3 => part_entries(table) + node.count, 5 => node.count }
            numbers.each do |register, number|
              @asm.lda(number & 0xFFFF)
              @asm.sta(@asm.direct(Memory.register(register)))
              @asm.lda(number >> 16)
              @asm.sta(@asm.direct(Memory.register(register) + 2))
            end
            call_routine("rt_list_copy")
          end

          # The runtime's list routine +routine+ on the list +node+ names, the list's place first.
          def list_call(routine, node, *args) = runtime_call(routine, [Build.int(list_place(node)), *args])

          def list_place(node)
            @lists.fetch(node.name) { raise LoweringError, "the list #{node.name.inspect} is used and never declared" }.first
          end

          # Reference#exec_table_get: the index made safe (LoweringPlan.index_kept_in_range). The
          # entry is read with a long address and X as the index, so the table can be in any bank.
          def value_of_table_get(node)
            table = @tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            bytes, signed = table_keeping(table)
            value(LoweringPlan.index_kept_in_range(node.index, table.values.length))
            return emit_read_split_entry(table, bytes, signed) if split?(table)

            @asm.lda(@asm.direct(R0))
            (bytes / 2).times { @asm.asl }
            @asm.tax
            label = table_label(table.name)
            @asm.lda(@asm.long_x(label))
            @asm.sta(@asm.direct(R0))
            if bytes == 4
              @asm.lda(@asm.long_x(label, 2))
              @asm.sta(@asm.direct(R0 + 2))
            else
              emit_widen_r0(bytes, signed)
            end
          end

          # The entry at the index in R0 of a table cut into parts, read through the part's place.
          def emit_read_split_entry(table, bytes, signed)
            emit_part_place(table)
            (bytes / 2).times { @asm.asl }
            @asm.tay
            @asm.lda(@asm.ind_long_y(R1))
            @asm.sta(@asm.direct(R0))
            if bytes == 4
              @asm.iny
              @asm.iny
              @asm.lda(@asm.ind_long_y(R1))
              @asm.sta(@asm.direct(R0 + 2))
            else
              emit_widen_r0(bytes, signed)
            end
          end

          # For the index in R0 of a table cut into parts: the place of the part it is in into R1
          # (three bytes, for an instruction to read through), and A the entry's number in that part.
          # A part holds a power of two of the table's own entries, so the part is the top bits of
          # the index and the number in it the rest. The index is short of 22 bits, as a cartridge is
          # at most four megabytes, so the part is the low half's top bits beside the high half's
          # bottom ones.
          def emit_part_place(table)
            per = part_entries(table)
            part_bits = 16 - per.bit_length + 1 # how many of the low half's top bits are the part's
            @asm.lda(@asm.direct(R0 + 2))
            part_bits.times { @asm.asl }
            @asm.sta(@asm.direct(R1))
            @asm.lda(@asm.direct(R0))
            @asm.asl # the top bit into the carry, and round in from the bottom
            part_bits.times { @asm.rol }
            @asm.and_a((1 << part_bits) - 1)
            @asm.ora(@asm.direct(R1))
            @asm.sta(@asm.direct(R1)) # three bytes a part's place: the part times three
            @asm.asl
            @asm.clc
            @asm.adc(@asm.direct(R1))
            @asm.tax
            label = table_label(table.name)
            @asm.lda(@asm.long_x(label))
            @asm.sta(@asm.direct(R1))
            @asm.lda(@asm.long_x(label, 1))
            @asm.sta(@asm.direct(R1 + 1))
            @asm.lda(@asm.direct(R0))
            @asm.and_a(per - 1)
          end

          # The low +bytes+ (1 or 2) of R0 made a whole number, with its sign or not.
          def emit_widen_r0(bytes, signed)
            done = fresh("widened")
            if bytes == 1
              @asm.lda(@asm.direct(R0))
              @asm.and_a(0x00FF)
              @asm.sta(@asm.direct(R0))
            end
            @asm.stz(@asm.direct(R0 + 2))
            return @asm.label(done) unless signed

            @asm.lda(@asm.direct(R0))
            @asm.cmp(bytes == 1 ? 0x0080 : 0x8000)
            @asm.bcc(done)
            if bytes == 1
              @asm.ora(0xFF00)
              @asm.sta(@asm.direct(R0))
            end
            @asm.dec(@asm.direct(R0 + 2))
            @asm.label(done)
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
              store_number(place_of(timer_number(node.name, what)), number)
            end
          end

          # Reference#exec_timer_stop: its count is kept.
          def emit_timer_stop(node) = store_number(place_of(timer_number(node.name, :running)), 0)

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
          # that stops or restarts its own timer still finishes the ticks this frame crossed. A
          # handler too big for a bank is cut into parts as a routine is (RoutineCuts).
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
                @asm.brl(top)
                @asm.label(done)
              end
            end
            [each_tick, *@cuts.part_sections(cut) { |part, statements| routine_section(part, statements, routine: routine) }]
          end

          # --- tests: jump unless one holds ---

          def jump_if(condition, label)
            known = folded(condition)
            return if known&.zero?
            return @asm.brl(label) if known

            go_on = fresh("holds_not")
            jump_unless(condition, go_on)
            @asm.brl(label)
            @asm.label(go_on)
          end

          # Jump to +label+ unless +condition+ holds. A comparison jumps on the flags it leaves, without
          # making a 1 or a 0 of it first.
          def jump_unless(condition, label)
            known = folded(condition)
            return (@asm.brl(label) if known.zero?) if known

            if binop?(condition, :and) && Unchanging.value?(condition.rhs) { |part| folded(part) }
              # The interpreter works both sides out; the second is skipped here when the first does
              # not hold, which is the same thing where working it out changes nothing.
              jump_unless(condition.lhs, label)
              jump_unless(condition.rhs, label)
            elsif (tested = comparison_in_truth_test(condition))
              comparison, holds = tested
              branch = compare(comparison)
              @asm.branch_long(holds ? branch : W65816::OPPOSITES.fetch(branch), label)
            elsif condition.is_a?(Node) && condition.kind == :binop && COMPARISONS.include?(condition.op)
              @asm.branch_long(compare(condition), label)
            else
              value(condition)
              @asm.lda(@asm.direct(R0))
              @asm.ora(@asm.direct(R0 + 2))
              @asm.branch_long(:beq, label)
            end
          end

          def binop?(node, op) = node.is_a?(Node) && node.kind == :binop && node.op == op

          # A comparison's answer tested against 1 OR 0 — `(2 < count) == 1`, which is how a pool's
          # drawing asks whether a slot is among the live ones — is the comparison itself, or its
          # opposite: a comparison is 1 or 0, so `== 1` and `!= 0` hold when it does, and `== 0` and
          # `!= 1` when it does not. Jumping on the comparison's own flags skips making a 1 or a 0
          # of it and comparing both halves of that. The comparison, and whether the test holds when
          # it does; or nil.
          def comparison_in_truth_test(condition)
            return unless binop?(condition, :==) || binop?(condition, :!=)

            [[condition.lhs, condition.rhs], [condition.rhs, condition.lhs]].each do |inner, other|
              next unless inner.is_a?(Node) && inner.kind == :binop && COMPARISONS.include?(inner.op) && !folded(inner)

              number = folded(other)
              next unless [0, 1].include?(number)

              return [inner, (condition.op == :==) == (number == 1)]
            end
            nil
          end

          # The two sides of a comparison compared, and the branch that is taken when it does not hold.
          #
          # Equal or not: the low halves compared and, when they match, the high halves; the zero flag
          # gives the answer. Less or more: the left subtracted from the right or the right from the left, the low
          # halves with CMP and the high halves with SBC and the borrow from the first, which leaves
          # the sign of the difference in the negative flag — unless the subtraction overflowed, in
          # which case the sign came out the wrong way round and is flipped back.
          def compare(node)
            op = node.op
            short = compare_short_counter(node) || compare_pool_slots(node)
            return short if short
            return compare_narrow_slot(op, *narrow_slot_and_number(node)) if narrow_slot_and_number(node)

            short = compare_within_halves(node) || compare_absolute_below(node)
            return short if short

            left, right = %i[> <=].include?(op) ? [node.rhs, node.lhs] : [node.lhs, node.rhs]
            with_both_halves(left, right) do |lefts, halves|
              if %i[== !=].include?(op)
                differ = fresh("differ")
                emit_low_half_load(lefts[0])
                @asm.cmp(halves[0])
                @asm.bne(differ)
                @asm.lda(lefts[1])
                @asm.cmp(halves[1])
                @asm.label(differ, join: true)
              else
                signed = fresh("signed")
                @asm.lda(lefts[0])
                @asm.cmp(halves[0])
                @asm.lda(lefts[1])
                @asm.sbc(halves[1])
                @asm.bvc(signed)
                @asm.eor(0x8000)
                @asm.label(signed, join: true)
              end
            end
            # The negative flag now shows left < right, where for > and <= the two were swapped.
            { :== => :bne, :!= => :beq, :< => :bpl, :> => :bpl, :>= => :bmi, :<= => :bmi }.fetch(op)
          end

          # Two numbers proven to stay in 16 BITS (NumberRanges), compared in 16. Such a number's high
          # half is only its sign spread upward, so its low half alone is the number, and the
          # processor's 16-bit accumulator compares two of them in one instruction: CMP for equal,
          # and for an order CMP's carry when neither is below nought, or a subtract whose sign is
          # turned back where it overflowed. Each side's low half is worked out by #emit_low_half,
          # with no high half made at all: a slot of bytes is read with its sign carried into the
          # high byte, a shift of a number that fits 16 bits is a shift of its 16. The 65816 has no
          # wider compare: CMP works on the accumulator's 8 or 16 bits as REP and SEP set it, which
          # is the width the console's code works its numbers at (fullsnes, "CPU 65XX
          # Microprocessor"). The branch taken when the comparison does not hold, as #compare gives,
          # or nil when either side is not proven.
          def compare_within_halves(node)
            op = node.op
            left, right = %i[> <=].include?(op) ? [node.rhs, node.lhs] : [node.lhs, node.rhs]
            ranges = [left, right].map { |side| proven_range(side) }
            # Two sides from 0 to 65535 are compared the same way, CMP's carry, with no sign to turn.
            unsigned = ranges.all? { |range| NumberRanges.inside?(range, NumberRanges::UNSIGNED_HALF) }
            return unless unsigned || ranges.all? { |range| within_half?(range) }

            operand = low_half_operand(right, 16)
            emit_low_half(left, 16)
            unless operand
              # The left side kept on the stack while the right is worked out, as the interpreter
              # works the left out first.
              @asm.pha
              emit_low_half(right, 16)
              @asm.sta(@asm.direct(R0))
              @asm.pla
              operand = @asm.direct(R0)
            end
            if %i[== !=].include?(op)
              @asm.cmp(operand)
              return op == :== ? :bne : :beq
            end
            if ranges.all? { |range| range.begin >= 0 }
              @asm.cmp(operand) # the carry is set when the left is not below the right
              return %i[< >].include?(op) ? :bcs : :bcc
            end

            signed = fresh("signed")
            @asm.sec
            @asm.sbc(operand)
            @asm.bvc(signed)
            @asm.eor(0x8000)
            @asm.label(signed, join: true)
            { :< => :bpl, :> => :bpl, :>= => :bmi, :<= => :bmi }.fetch(op)
          end

          def within_half?(range) = NumberRanges.inside?(range, NumberRanges::HALF)

          # How far apart, tested against a small number: `(other.x - e.x).abs < 16`, a thing checking
          # whether another is near it, which a game asks for every pair of things every frame. Worked
          # out the long way, the difference is made positive (a negate of both halves when it is not)
          # and then compared, signed, in both halves with the number. Here the difference's high half
          # is left in A as it is worked out, and that alone says which of three cases it is:
          #
          #   nought      the difference is its low half, compared, unsigned, with the number;
          #   all ones    it is below nought, and nearer than 65536 unless the low half is nought, so
          #               nought less the low half is how far apart, compared the same way;
          #   otherwise   too far apart, with one exception the interpreter keeps: the most negative
          #               number has no positive and stays itself (IR::Int32.neg), which is below any
          #               number, so its test holds.
          #
          # Each case ends with A holding how far apart (or $FFFF, never below the number, for too
          # far) and one compare with the number, so the branch after it is the same for all three.
          # Only for a number written in the program from 1 to $7FFF: below that the test never holds
          # but for the most negative number, and the long way says so.
          def compare_absolute_below(node)
            distance, limit = absolute_and_limit(node)
            return unless distance
            return compare_half_distance_below(distance.operand, limit) if half_slot_sum?(distance.operand)

            held = fresh("near")
            far = fresh("far")
            too_far = fresh("too_far")
            positive = fresh("near_positive")
            emit_high_half_in_a(distance.operand)
            @asm.beq(positive)
            @asm.inc(:a)
            @asm.bne(far)
            @asm.lda(0)
            @asm.sec
            @asm.sbc(@asm.direct(R0))
            @asm.bcc(held) # a borrow: the low half was not nought, and A is how far apart
            @asm.label(far) # A is the high half plus one: $8001 for the most negative number
            @asm.cmp(0x8001)
            @asm.bne(too_far)
            @asm.lda(@asm.direct(R0))
            @asm.beq(held) # the most negative number: nought, which is below the number
            @asm.label(too_far)
            @asm.lda(0xFFFF)
            @asm.bra(held)
            @asm.label(positive)
            @asm.lda(@asm.direct(R0))
            @asm.label(held)
            @asm.cmp(limit)
            :bcs
          end

          # How far apart two half-word slots are, tested against a small number: a pool whose places
          # are kept in half words (`widths: { x: :half }`), checking one thing against another. Each
          # slot reads back as a number from -32768 to 32767, so the difference fits in 17 bits, and
          # the processor's 16-bit subtract says all of it: when it does not overflow, the 16 bits are
          # the difference; when it does, the difference is 32768 or more away from nought and the test
          # cannot hold. So the left side is read into R0 (first, as the interpreter reads it), the
          # right read at X and the two subtracted, and how far apart is made positive in A, with no high half worked out at all. A sum is the
          # same with an add. The branch taken when the test does not hold, as #compare gives.
          def compare_half_distance_below(node, limit)
            held = fresh("near")
            within = fresh("within_half")
            left = half_slot_operand(node.lhs)
            if kept_read(node.rhs)
              # The right side is a number of the routine's own, read where it is: no X to set.
              right = half_slot_operand(node.rhs)
              emit_carry_for(node.op)
              @asm.lda(left)
            else
              @asm.lda(left)
              @asm.sta(@asm.direct(R0))
              right = half_slot_operand(node.rhs)
              emit_carry_for(node.op)
              @asm.lda(@asm.direct(R0))
            end
            emit_half_sum(node.op, right)
            @asm.bvc(within)
            @asm.lda(0xFFFF) # overflowed: 32768 or more apart
            @asm.bra(held)
            @asm.label(within)
            @asm.bpl(held)
            @asm.eor(0xFFFF)
            @asm.inc(:a)
            @asm.label(held)
            @asm.cmp(limit)
            :bcs
          end

          # Whether +node+ is a sum or difference of two half-word slots of lists, each read where it
          # is (#compare_half_distance_below).
          def half_slot_sum?(node)
            sum_in_halves?(node) && %i[+ -].include?(node.op) && !folded(node) &&
              [node.lhs, node.rhs].all? { |side| half_slot_read?(side) }
          end

          # Whether +node+ reads a slot of two bytes where it is, at an index needing nothing worked
          # out. Asked by #half_slot_sum? and #emit_sum_into.
          def half_slot_read?(node)
            plain_slot_read?(node) && !folded(node) && !unsigned_list?(node.name) &&
              list_placed(node)[2] == 2 && !index_in_place(node.index).nil?
          end

          # Where the half-word slot +node+ (#half_slot_read?) is, with X set to reach it, or the low
          # half of the number it is kept in before its loop (#with_invariant_reads_kept), which holds
          # the slot's half word as it reads back.
          def half_slot_operand(node)
            kept = kept_read(node)
            return at_place(place_of(kept)) if kept

            place, = list_placed(node)
            slot = fixed_slot_address(node)
            return @asm.long(slot) if slot

            emit_slot_into_x(place, list_slots(node).stride, index_in_place(node.index), checked: !index_inside_full_list?(node.name, node.index))
            @asm.long_x(list_slots(node).base)
          end

          # The `abs` and the number it must be below, for a test #compare_absolute_below takes, or nil.
          def absolute_and_limit(node)
            distance, bound, inclusive = case node.op
                                         when :< then [node.lhs, node.rhs, false]
                                         when :<= then [node.lhs, node.rhs, true]
                                         when :> then [node.rhs, node.lhs, false]
                                         when :>= then [node.rhs, node.lhs, true]
                                         end
            return unless distance.is_a?(Node) && distance.kind == :absolute && !folded(distance)

            limit = folded(bound)
            return unless limit

            limit += 1 if inclusive
            [distance, limit] if limit.between?(1, 0x7FFF)
          end

          # +node+ worked out with its low half in R0 and its high half in a. A sum or difference
          # ends on its high half, which is not stored.
          def emit_high_half_in_a(node)
            unless sum_in_halves?(node) && %i[+ -].include?(node.op) && !folded(node)
              value(node)
              return @asm.lda(@asm.direct(R0 + 2))
            end

            with_both_halves(without_added_nought(node.lhs), node.rhs) do |lefts, halves|
              emit_carry_for(node.op)
              @asm.lda(lefts[0])
              emit_half_sum(node.op, halves[0])
              @asm.sta(@asm.direct(R0))
              @asm.lda(lefts[1])
              emit_half_sum(node.op, halves[1])
            end
          end

          # A byte or half slot of a list tested equal, or not, to a number written in the program. A
          # narrow slot reads back with its top bit as the sign (#emit_read_slot_at_x), so it equals a
          # number that fits its width exactly when its own bits are that number's low bits: one
          # compare of the slot where it is, where reading it out as 32 bits takes the sign worked
          # out, both halves stored, and both compared. A pool keeps which slots are live, and each
          # field a game narrows, in such slots, and asks them this every walk.
          #
          # The list and the number, or nil when +node+ is not such a test.
          def narrow_slot_and_number(node)
            return unless %i[== !=].include?(node.op)

            [[node.lhs, node.rhs], [node.rhs, node.lhs]].each do |slot, other|
              # An unsigned slot's sixteen bits are not the number's: 65535 is not -1.
              next unless plain_slot_read?(slot) && !unsigned_list?(slot.name)

              number = folded(other)
              next if number.nil? || folded(slot)

              width = list_placed(slot)[2]
              bits = 8 * width
              return [slot, number] if width < 4 && number.between?(-(1 << (bits - 1)), (1 << (bits - 1)) - 1)
            end
            nil
          end

          def compare_narrow_slot(op, slot, number)
            place, _capacity, width = list_placed(slot)
            emit_slot_into_x(place, list_slots(slot).stride, index_halves(slot.index), checked: !index_inside_full_list?(slot.name, slot.index))
            @asm.lda(@asm.long_x(list_slots(slot).base))
            @asm.and_a(0x00FF) if width == 1
            @asm.cmp(number & (width == 1 ? 0xFF : 0xFFFF))
            op == :== ? :bne : :beq
          end

          # --- values: each leaves its number in R0 ---

          # A value the lowering makes for itself beside the IR's: where a label is, all 24 bits.
          LongAddress = Data.define(:label)

          def value(operand)
            known = folded(operand)
            return load_constant(known) if known

            case operand
            when Symbol then load_variable(operand)
            when Node then value_of_kind(operand)
            when LongAddress then load_long_address(operand.label)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def load_long_address(label)
            @asm.lda(@asm.imm(label))
            @asm.sta(@asm.direct(R0))
            @asm.lda(@asm.bank_of(label))
            @asm.and_a(0x00FF)
            @asm.sta(@asm.direct(R0 + 2))
          end

          def value_of_int(node) = load_constant(node.value)

          # A cartridge is played by one person, the first player.
          def value_of_local_player(_node) = load_constant(1)

          # The first player, and each one after up to the highest whose button has been down
          # (Runtime::Frame::PLAYERS_PAST_FIRST, which never falls).
          def value_of_players_connected(_node)
            @asm.lda(@asm.abs(@memory[Runtime::Frame::PLAYERS_PAST_FIRST]))
            @asm.inc
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end
          def value_of_var_ref(node) = load_variable(node.name)

          def value_of_binop(node)
            return value_of_comparison(node) if COMPARISONS.include?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)
            return if node.op == :* && emit_product_by_written_number(node)
            return if node.op == :* && emit_product_by_comparison(node)
            return if node.op == :% && emit_remainder_by_power_of_two(node)
            return if node.op == :/ && emit_quotient_by_power_of_two(node)
            return if %i[/ %].include?(node.op) && emit_divide_by_written_byte(node)
            return if %i[<< >>].include?(node.op) && emit_shift_by_written_count(node)

            if (routine = CALLED_SUMS[node.op])
              @divides ||= %i[/ %].include?(node.op)
              return runtime_call(routine, [node.lhs, node.rhs])
            end
            emit_sum_into(node, r0_halves)
          end

          # Where R0's two halves are, as operands.
          def r0_halves = [@asm.direct(R0), @asm.direct(R0 + 2)]

          # Is +node+ a sum written a half at a time (+, -, &, | or ^), which #emit_sum_into can
          # leave anywhere?
          def sum_in_halves?(node) = node.is_a?(Node) && node.kind == :binop && IN_PLACE_OPS.include?(node.op)

          # A sum written a half at a time, each half stored into +to+ (two operands) as soon as it is
          # worked out. Each half of +to+ is written only after both sides' same half are read, and the
          # carry between them is in the processor's flags, so +to+ may be one of the sides: `x = x + 1`.
          def emit_sum_into(node, to)
            return emit_bitwise_halves(node, to) if BITWISE.include?(node.op)
            return emit_sum_of_half_slot_into(node, to) if half_slot_read?(node.rhs) && operand_halves(node.rhs).nil?

            with_both_halves(without_added_nought(node.lhs), node.rhs) do |lefts, halves|
              emit_carry_for(node.op)
              2.times do |i|
                @asm.lda(lefts[i])
                emit_half_sum(node.op, halves[i])
                @asm.sta(to[i])
              end
            end
          end

          # A whole number plus or minus a slot of two bytes, `x += dx` with a step kept in half words:
          # the slot's low half added where it is, at X, and its high half, nought or all ones by its
          # sign, added as a number written in the program, picked by a branch on the sign. The carry
          # from the low halves is kept across the load and the branch, which leave it alone. The
          # left side is worked out first, as the interpreter takes them.
          def emit_sum_of_half_slot_into(node, to)
            left = without_added_nought(node.lhs)
            lefts = operand_halves(left)
            unless lefts
              value(left)
              lefts = r0_halves
            end
            place, = list_placed(node.rhs)
            slot = fixed_slot_address(node.rhs)
            unless slot
              emit_slot_into_x(place, list_slots(node.rhs).stride, index_in_place(node.rhs.index),
                               checked: !index_inside_full_list?(node.rhs.name, node.rhs.index))
            end
            right = slot ? @asm.long(slot) : @asm.long_x(list_slots(node.rhs).base)
            positive = fresh("step_positive")
            added = fresh("step_added")
            emit_carry_for(node.op)
            @asm.lda(lefts[0])
            emit_half_sum(node.op, right)
            @asm.sta(to[0])
            @asm.lda(right)
            @asm.bpl(positive)
            @asm.lda(lefts[1])
            emit_half_sum(node.op, @asm.imm(0xFFFF))
            @asm.bra(added)
            @asm.label(positive, join: true)
            @asm.lda(lefts[1])
            emit_half_sum(node.op, @asm.imm(0))
            @asm.label(added, join: true)
            @asm.sta(to[1])
          end

          # +node+ with any nought added to it or taken from it left out, since that changes nothing:
          # a sprite's bottom is its place, plus where its box starts in it (often nought), plus the
          # box's height, and the sum is then one add rather than two.
          def without_added_nought(node)
            node = node.lhs while sum_in_halves?(node) && %i[+ -].include?(node.op) && folded(node.rhs)&.zero?
            node
          end

          # A comparison as a 1 when it holds and a 0 when it does not.
          def value_of_comparison(node)
            fails = fresh("fails")
            done = fresh("compared")
            @asm.branch_long(compare(node), fails)
            @asm.lda(1)
            @asm.bra(done)
            @asm.label(fails)
            @asm.lda(0)
            @asm.label(done)
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end

          # `and` and `or` work both sides out, as the interpreter does, and give a 1 or a 0.
          def value_of_both_or_either(node)
            with_right_halves(node.lhs, node.rhs) do |halves|
              emit_truth_of_halves(halves, R0 + 4)
              emit_truth_of_halves([@asm.direct(R0), @asm.direct(R0 + 2)], R0)
              @asm.lda(@asm.direct(R0))
              node.op == :and ? @asm.and_a(@asm.direct(R0 + 4)) : @asm.ora(@asm.direct(R0 + 4))
              @asm.sta(@asm.direct(R0))
              @asm.stz(@asm.direct(R0 + 2))
            end
          end

          # The word at the direct page address +at+ made 1 when the number in +halves+ is not nought,
          # and 0 when it is.
          def emit_truth_of_halves(halves, at)
            nought = fresh("nought")
            @asm.lda(halves[0])
            @asm.ora(halves[1])
            @asm.beq(nought)
            @asm.lda(1)
            @asm.label(nought)
            @asm.sta(@asm.direct(at))
          end

          def value_of_neg(node)
            value(node.operand)
            emit_negate_r0
          end

          def value_of_bit_not(node)
            value(node.operand)
            [R0, R0 + 2].each do |at|
              @asm.lda(@asm.direct(at))
              @asm.eor(0xFFFF)
              @asm.sta(@asm.direct(at))
            end
          end

          # A sum or difference worked out a half at a time ends storing its high half from A, so the
          # high half is not read back to test its sign.
          def value_of_absolute(node)
            done = fresh("positive")
            value(node.operand)
            operand = node.operand
            @asm.lda(@asm.direct(R0 + 2)) unless sum_in_halves?(operand) && %i[+ -].include?(operand.op) && !folded(operand)
            @asm.bpl(done)
            emit_negate_r0
            @asm.label(done)
          end

          # Reference#clamp_value: held at the floor, then at the ceiling.
          def value_of_clamped(node)
            value(node.operand)
            [[node.min, :<], [node.max, :>]].each do |bound, op|
              halves = operand_halves(bound)
              unless halves
                # The bound worked out with the number so far kept on the stack, then into R1.
                @asm.pei(@asm.direct(R0 + 2))
                @asm.pei(@asm.direct(R0))
                value(bound)
                [0, 2].each do |half|
                  @asm.lda(@asm.direct(R0 + half))
                  @asm.sta(@asm.direct(R1 + half))
                end
                pull_into(R0)
                halves = [@asm.direct(R1), @asm.direct(R1 + 2)]
              end
              within = fresh("within")
              emit_compare_r0(op, halves, within)
              @asm.lda(halves[0])
              @asm.sta(@asm.direct(R0))
              @asm.lda(halves[1])
              @asm.sta(@asm.direct(R0 + 2))
              @asm.label(within)
            end
          end

          # A jump to +within+ unless R0 +op+ (< or >) the number in +halves+.
          def emit_compare_r0(op, halves, within)
            signed = fresh("signed")
            if op == :<
              @asm.lda(@asm.direct(R0))
              @asm.cmp(halves[0])
              @asm.lda(@asm.direct(R0 + 2))
              @asm.sbc(halves[1])
            else
              @asm.lda(halves[0])
              @asm.cmp(@asm.direct(R0))
              @asm.lda(halves[1])
              @asm.sbc(@asm.direct(R0 + 2))
            end
            @asm.bvc(signed)
            @asm.eor(0x8000)
            @asm.label(signed)
            @asm.branch_long(:bpl, within)
          end

          def value_of_mul_fix(node) = emit_fraction_call("rt_mul_fix", node)
          def value_of_div_fix(node) = emit_fraction_call("rt_div_fix", node)

          # The kinds of value #emit_fraction_call makes.
          FRACTION_KINDS = %i[mul_fix div_fix].freeze

          # Whether +program+ names a multiply or divide of numbers with a fraction anywhere, so its
          # runtime can carry the routines for them (#fractions?, known only once it is lowered):
          # asked before, for the room their scratch takes (Runtime.scratch_bytes).
          def self.fractions_named?(program) = program.walk.any? { |node| FRACTION_KINDS.include?(node.kind) }

          def emit_fraction_call(routine, node)
            @fractions = true
            runtime_call(routine, [node.lhs, node.rhs, fraction_bits(node)])
          end

          def value_of_shift_right(node)
            value(node.operand)
            emit_shift_right_of_r0(node.bits)
          end

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = value(Build.binop(:<, node.draw, Build.int(node.percent)))

          # How many bits of a number hold its fraction: the runtime's sums are written for 0 to 32,
          # every scale the framework uses.
          def fraction_bits(node)
            bits = node.fraction_bits
            unless bits.between?(0, 32)
              raise LoweringError, "a number with #{bits} bits of fraction is more than the Super Nintendo build can " \
                                   "work out. It can work out 0 to 32."
            end

            Build.int(bits)
          end

          # The buttons held, or pressed, through the pass: a bit each, in IR::Buttons's order, and
          # any of them for Buttons::ANY. Each other controller's are a word of their own, with
          # the same bits, and any player is every word the game reads together
          # (Runtime::Frame::CONTROLLERS).
          def value_of_held(node) = emit_button_truth(Runtime::Frame::CONTROLLERS.map(&:held), node)
          def value_of_pressed(node) = emit_button_truth(Runtime::Frame::CONTROLLERS.map(&:pressed), node)

          # +words+ is where each controller's buttons are kept, the first player's first.
          def emit_button_truth(words, node)
            mask = button_truth_mask(node.button)
            nought = fresh("not_down")
            if node.player == Buttons::ANY
              read = words.select { |name| @memory.reserved?(name) }
              @asm.lda(@asm.abs(@memory[read.first]))
              read.drop(1).each { |name| @asm.ora(@asm.abs(@memory[name])) }
            else
              @asm.lda(@asm.abs(@memory[words.fetch(node.player - 1)]))
            end
            @asm.and_a(mask)
            @asm.beq(nought)
            @asm.lda(1)
            @asm.label(nought)
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end

          def button_truth_mask(button)
            return Buttons.mask(Console::SUPER_NINTENDO.buttons) if button == Buttons::ANY

            1 << (Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}")
          end

          # R0 = the variable +name+; one kept in two bytes made whole, its sign spread over the high
          # half.
          def load_variable(name)
            if half_variable?(name)
              @asm.lda(low_half_of(name))
              @asm.sta(@asm.direct(R0))
              emit_sign_of_a
              return @asm.sta(@asm.direct(R0 + 2))
            end

            at = place_of(name)
            @asm.lda(at_place(at))
            @asm.sta(@asm.direct(R0))
            @asm.lda(at_place(at + 2))
            @asm.sta(@asm.direct(R0 + 2))
          end

          def load_constant(number)
            number &= 0xFFFF_FFFF
            [number & 0xFFFF, number >> 16].each_with_index do |half, i|
              if half.zero?
                @asm.stz(@asm.direct(R0 + (2 * i)))
              else
                @asm.lda(half)
                @asm.sta(@asm.direct(R0 + (2 * i)))
              end
            end
          end

          # R0 turned round: every bit flipped and one added, as two halves with a borrow between them.
          def emit_negate_r0
            @asm.sec
            [R0, R0 + 2].each do |at|
              @asm.lda(0)
              @asm.sbc(@asm.direct(at))
              @asm.sta(@asm.direct(at))
            end
          end

          def folded(node) = @plan.folded(node)

          def variable_named(node)
            return node if node.is_a?(Symbol)
            return unless node.is_a?(Node)
            return node.name if node.kind == :var_ref

            kept_read(node)
          end

          # A list's slot that a loop reads on every turn and never changes, read once before it. A
          # thing of a pool checked against each other thing reads its own fields at its own slot
          # for every pair: `(other.x - e.x).abs < 16`, where `e`'s slot and the field's list stay as
          # they are through the walk. Each such read, worked out every turn, sets X to the slot and
          # reads it there, or works it into R0 beside the other side; read once into a number of the
          # routine's own before the loop, it is a variable on every turn, which a sum or a comparison
          # reads where it is.
          #
          # A read is kept so when its index is a variable and nothing in the loop names that
          # variable or the list but to read them, the loop calls nothing and has no frame boundary
          # in it (LoweringPlan::FRAME_ENDING_KINDS), so nothing else runs while it goes, and its
          # index cannot be outside the list (#index_inside_full_list?), so reading it first, even for
          # a loop that never reads it, cannot stop the game.
          def with_invariant_reads_kept(node)
            kept = invariant_reads(node).to_h do |read|
              number = keep_local(:kept_read, every_turn: true)
              value(read)
              store(number)
              [[read.name, read.index.name], number]
            end
            outer = @kept_reads
            @kept_reads = (outer || {}).merge(kept)
            yield
          ensure
            @kept_reads = outer
          end

          # The reads of +loop+ #with_invariant_reads_kept keeps, one for each list and index.
          def invariant_reads(loop)
            nodes = loop.walk.to_a
            return [] if nodes.any? { |each| each.callees.any? || LoweringPlan::FRAME_ENDING_KINDS.include?(each.kind) }

            reads = nodes.select do |each|
              each.kind == :list_get && each.index.is_a?(Node) && each.index.kind == :var_ref && !folded(each) &&
                !front_dropped_lists.include?(each.name) && index_inside_full_list?(each.name, each.index) &&
                !kept_read(each)
            end
            reads.uniq { |read| [read.name, read.index.name] }.reject do |read|
              nodes.any? { |each| names?(each, read.index.name, :var_ref) || names?(each, read.name, :list_get) }
            end
          end

          # Whether +node+, other than a node of kind +reader+, names +name+ in what it holds.
          def names?(node, name, reader)
            node.kind != reader && node.attrs.values.flatten.any?(name)
          end

          # The number a read is kept in before its loop (#with_invariant_reads_kept), or nil.
          def kept_read(node)
            return unless @kept_reads && node.kind == :list_get && node.index.is_a?(Node) && node.index.kind == :var_ref

            @kept_reads[[node.name, node.index.name]]
          end

          # Where the two halves of +node+ can be read without working anything out: the number itself
          # for one written in the program, the variable's place for a variable; or nil. A variable
          # kept in two bytes has no high half to read (HalfVariables), so it is worked out.
          def operand_halves(node)
            known = folded(node)
            return [@asm.imm(known & 0xFFFF), @asm.imm((known >> 16) & 0xFFFF)] if known

            name = variable_named(node)
            return nil unless name && !half_variable?(name)

            at = place_of(name)
            [at_place(at), at_place(at + 2)]
          end

          # The left side worked out into R0, and the block handed where the two halves of the right
          # side are: in place when it needs nothing worked out, at X when it is a word slot of a list
          # (#slot_read_at_x?), and otherwise worked out first, pushed, and pulled into R1 once the
          # left side is in R0. With +slot_at_x+ false no side is read at X, for a block that sets X
          # itself before it reads the halves.
          def with_right_halves(left, right, slot_at_x: true)
            halves = operand_halves(right)
            if halves
              value(left)
              return yield(halves)
            end
            if slot_at_x && slot_read_at_x?(right)
              value(left)
              return yield(slot_halves_at_x(right))
            end

            push_value(right)
            value(left)
            pull_into(R1)
            yield [@asm.direct(R1), @asm.direct(R1 + 2)]
          end

          # The block handed where the two halves of each side are. A side that needs nothing worked
          # out is read where it is, and so is a word slot of a list beside such a side, at X. When
          # only the right side needs working out, it is worked out into R0 and the left read where
          # it is, with nothing pushed: reading a variable or a written number gives the same before
          # or after, so the order cannot show. Otherwise the left side is worked out into R0 as
          # #with_right_halves has it.
          def with_both_halves(left, right, slot_at_x: true)
            lefts = operand_halves(left)
            rights = operand_halves(right)
            return yield(lefts, rights) if lefts && rights

            if slot_at_x
              return yield(lefts, slot_halves_at_x(right)) if lefts && slot_read_at_x?(right)
              return yield(slot_halves_at_x(left), rights) if rights && slot_read_at_x?(left)
            end
            in_r0 = [@asm.direct(R0), @asm.direct(R0 + 2)]
            if lefts
              value(right)
              return yield(lefts, in_r0)
            end

            with_right_halves(left, right, slot_at_x: slot_at_x) { |halves| yield(in_r0, halves) }
          end

          # A word slot of a list read where it is, as one side of a sum or a comparison: X set to the
          # slot from an index that needs nothing worked out, and the two halves read at X by the
          # instruction that uses them. Worked out into R0 instead, the slot is read and stored, then
          # pushed and pulled back beside the other side; a check of one pool thing against another,
          # `(other.x - e.x).abs < 16`, does that for both of its fields on every pair. A value never
          # writes a list, so the slot reads the same after the other side is worked out as before.
          # A slot narrower than a word has its sign worked out first, and is not read so.
          def slot_read_at_x?(node)
            plain_slot_read?(node) && !folded(node) &&
              list_placed(node)[2] == 4 && !index_in_place(node.index).nil?
          end

          # Where the two halves of +node+ (#slot_read_at_x?) are, with X set to reach them.
          def slot_halves_at_x(node)
            place, = list_placed(node)
            slot = fixed_slot_address(node)
            return [@asm.long(slot), @asm.long(slot, 2)] if slot

            emit_slot_into_x(place, list_slots(node).stride, index_in_place(node.index), checked: !index_inside_full_list?(node.name, node.index))
            [@asm.long_x(list_slots(node).base), @asm.long_x(list_slots(node).base, 2)]
          end

          # The number +node+ worked out into R0 and pushed, high half first, so the stack holds it
          # low half on top.
          def push_value(node)
            value(node)
            @asm.pei(@asm.direct(R0 + 2))
            @asm.pei(@asm.direct(R0))
          end

          def pull_into(at)
            @asm.pla
            @asm.sta(@asm.direct(at))
            @asm.pla
            @asm.sta(@asm.direct(at + 2))
          end

          # What is left after dividing by a power of two written in the program, as Int32.mod has it:
          # the sign of the divisor. By a positive one it is the low bits alone (-1 % 16 is 15, and so
          # is -1 & 15) — an AND of each half, where the runtime's division takes a loop of 32 steps.
          # By a negative one, low bits that are not nought are counted down from the divisor: 1 % -16
          # is -15. True when it was done so.
          def emit_remainder_by_power_of_two(node)
            divisor = folded(node.rhs)
            size = divisor&.abs
            return false unless divisor && ConstantDivisor.shift_bits(size)

            value(Build.binop(:&, node.lhs, Build.int(size - 1)))
            return true if divisor.positive?

            done = fresh("remainder_signed")
            @asm.lda(@asm.direct(R0))
            @asm.ora(@asm.direct(R0 + 2))
            @asm.beq(done)
            @asm.sec
            2.times do |half|
              @asm.lda(@asm.direct(R0 + (2 * half)))
              @asm.sbc((size >> (16 * half)) & 0xFFFF)
              @asm.sta(@asm.direct(R0 + (2 * half)))
            end
            @asm.label(done)
            true
          end

          # A quotient by a power of two written in the program, as a shift, turned round after for a
          # negative one. A shift right rounds down and a quotient rounds towards nought, so a negative
          # number has the size less one added first: -7 / 2 is (-7 + 1) >> 1, which is -3. By 1 or -1
          # it is the number, or the number turned round. True when it was done so.
          def emit_quotient_by_power_of_two(node)
            divisor = folded(node.rhs)
            size = divisor&.abs
            places = divisor && ConstantDivisor.shift_bits(size)
            return false unless places

            value(node.lhs)
            unless places.zero?
              positive = fresh("positive")
              @asm.lda(@asm.direct(R0 + 2))
              @asm.bpl(positive)
              @asm.clc
              2.times do |half|
                @asm.lda(@asm.direct(R0 + (2 * half)))
                @asm.adc(((size - 1) >> (16 * half)) & 0xFFFF)
                @asm.sta(@asm.direct(R0 + (2 * half)))
              end
              @asm.label(positive)
              emit_shift_right_of_r0(places)
            end
            emit_negate_r0 if divisor.negative?
            true
          end

          # The console divides 16 BITS BY A BYTE BY ITSELF: a number written to WRDIVL and WRDIVH and a
          # byte to WRDIVB, and sixteen cycles later the quotient is at RDDIVL and the remainder at
          # RDMPYL. So a `/` or `%` by a byte written in the program, of a number that turns out to be
          # from nought to 65535 (a score, a count, a place on the screen: what a game divides by ten
          # most), is that and nothing else, written where the sum is. By a negative byte the quotient
          # is turned round, and a remainder that is not nought counted down from the divisor (Int32.mod:
          # 1 % -10 is -9). Any other number, below nought or with a top half, goes to the runtime's
          # rt_div32 or rt_mod32, which give every one its sign and divide a top half too. A power of two
          # is a shift instead (#emit_quotient_by_power_of_two). True when it was done so.
          def emit_divide_by_written_byte(node)
            divisor = folded(node.rhs)
            size = divisor&.abs
            return false unless size&.between?(3, 0xFF) && !ConstantDivisor.shift_bits(size)

            h = Console::SNESHardware
            wide = fresh("divide_wide")
            done = fresh("divided")
            value(node.lhs)
            @asm.lda(@asm.direct(R0 + 2))
            @asm.bne(wide)
            @asm.lda(@asm.direct(R0))
            @asm.sta(@asm.abs(h::WRDIVL)) # both bytes, this and WRDIVH
            @asm.sep(0x20)
            @asm.lda(size)
            @asm.sta(@asm.abs(h::WRDIVB))
            @asm.rep(0x20)
            7.times { @asm.nop } # the sixteen cycles the divider takes, with the REP
            @asm.lda(@asm.abs(node.op == :/ ? h::RDDIVL : h::RDMPYL))
            @asm.sta(@asm.direct(R0))
            emit_divider_answer_signed(node.op, size) if divisor.negative?
            @asm.bra(done)
            @asm.label(wide)
            @divides = true
            @asm.lda(divisor & 0xFFFF)
            @asm.sta(@asm.direct(R1))
            if divisor.negative?
              @asm.lda(0xFFFF)
              @asm.sta(@asm.direct(R1 + 2))
            else
              @asm.stz(@asm.direct(R1 + 2))
            end
            call_routine(CALLED_SUMS.fetch(node.op))
            @asm.label(done)
            true
          end

          # The divider's answer for +op+ in R0's low half, its top half nought, given a negative
          # divisor's sign: the quotient turned round, or the remainder less the size unless it is nought.
          def emit_divider_answer_signed(op, size)
            return emit_negate_r0 if op == :/

            zero = fresh("remainder_zero")
            @asm.beq(zero) # the flags are the remainder's, from the load before its store
            @asm.sec
            @asm.sbc(size)
            @asm.sta(@asm.direct(R0))
            @asm.lda(0xFFFF)
            @asm.sta(@asm.direct(R0 + 2))
            @asm.label(zero)
          end

          # A shift by a number written in the program is written in place, never as a call of
          # rt_shl32 or rt_shr32, which move the number a bit at a time round a loop. The 65816 can
          # read and write 16 bits at any byte, so a shift by a whole byte is a move: a load from
          # one byte along and a store, two instructions a half. A shift by sixteen is a move of
          # one half into the other. What is left after the bytes, seven places at most, is a turn
          # of A and a turn of the other half in memory for each place, with no count to keep and
          # no loop. `x >> 8` is then nine instructions, where the runtime took eight turns of a
          # loop of six, and the call and the count before them.

          # R0 shifted left +places+ (Int32.shift_left): emptied for a count of 32 or more, or below
          # nought.
          def emit_shift_left_of_r0(places)
            unless places.between?(0, 31)
              @asm.stz(@asm.direct(R0))
              return @asm.stz(@asm.direct(R0 + 2))
            end

            if places >= 16
              @asm.lda(@asm.direct(R0))
              @asm.sta(@asm.direct(R0 + 2))
              @asm.stz(@asm.direct(R0))
              places -= 16
            end
            if places >= 8
              @asm.lda(@asm.direct(R0 + 1)) # bytes 1 and 2, to be bytes 2 and 3
              @asm.sta(@asm.direct(R0 + 2))
              @asm.lda(@asm.direct(R0))
              @asm.xba # byte 0 up to be byte 1, and nought below it
              @asm.and_a(0xFF00)
              @asm.sta(@asm.direct(R0))
              places -= 8
            end
            return if places.zero?

            @asm.lda(@asm.direct(R0))
            places.times do
              @asm.asl # the low half's top bit into the carry...
              @asm.rol(@asm.direct(R0 + 2)) # ...and in at the bottom of the high half
            end
            @asm.sta(@asm.direct(R0))
          end

          # R0 shifted right +places+, rounding down as the arithmetic shift does
          # (Int32.shift_right): only its sign is left for a count of 31 or more, or below nought.
          def emit_shift_right_of_r0(places)
            return emit_sign_of_r0 unless places.between?(0, 30)

            if places >= 16
              emit_sign_of_r0(low: false)
              places -= 16
            end
            if places >= 8
              done = fresh("byte_signed")
              @asm.lda(@asm.direct(R0 + 1)) # bytes 1 and 2, to be bytes 0 and 1
              @asm.sta(@asm.direct(R0))
              @asm.lda(@asm.direct(R0 + 2))
              @asm.xba # byte 3 down to be byte 2...
              @asm.and_a(0x00FF)
              @asm.cmp(0x0080)
              @asm.bcc(done)
              @asm.ora(0xFF00) # ...and its sign above it
              @asm.label(done)
              @asm.sta(@asm.direct(R0 + 2))
              places -= 8
            end
            return if places.zero?

            @asm.lda(@asm.direct(R0 + 2))
            places.times do
              @asm.cmp(0x8000) # the sign into the carry, to come in at the top
              @asm.ror # the high half's bottom bit into the carry...
              @asm.ror(@asm.direct(R0)) # ...and in at the top of the low half
            end
            @asm.sta(@asm.direct(R0 + 2))
          end

          # R0's high half moved into its low half, and the high half made its sign: every bit one
          # for a negative number and nought otherwise. With +low+, the low half is made the sign
          # too, which is what a shift right too far for any bit to be left gives.
          def emit_sign_of_r0(low: true)
            positive = fresh("sign_positive")
            @asm.ldx(0)
            @asm.lda(@asm.direct(R0 + 2))
            @asm.sta(@asm.direct(R0)) unless low
            @asm.bpl(positive)
            @asm.dex
            @asm.label(positive)
            @asm.stx(@asm.direct(R0)) if low
            @asm.stx(@asm.direct(R0 + 2))
          end

          # A product by a number written in the program is written in place, never as a call of
          # rt_mul32. By a power of two it is a shift left (#emit_shift_left_of_r0), none at all for
          # one; by any other number up to 255 either way it is four turns of the console's own
          # multiplier (#emit_product_by_byte_of_r0); a number below nought turns the product round
          # after. rt_mul32 took its numbers handed over, the jump there and back, and, for a number
          # that is not a small one at or above nought, a loop of a dozen instructions for each of
          # its 32 bits. True when it was done so.
          def emit_product_by_written_number(node)
            [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
              number = folded(by)
              next unless number

              size = number.abs
              power = size.positive? && (size & (size - 1)).zero?
              next unless power || size <= 0xFF

              value(other)
              if size.zero?
                @asm.stz(@asm.direct(R0))
                @asm.stz(@asm.direct(R0 + 2))
              elsif power
                emit_shift_left_of_r0(size.bit_length - 1)
              else
                emit_product_by_byte_of_r0(size)
              end
              emit_negate_r0 if number.negative?
              return true
            end
            false
          end

          # A product by a comparison is the other number while the comparison holds and nought while
          # it does not, since a comparison is 1 or 0. That is how a sprite declared in a scene, or
          # under an `if`, is shown only while its scene is up or its test holds: its shown flag
          # times `state == 3`, worked out for every such sprite in every pass. So the comparison
          # jumps on its own flags to making R0 nought when it does not hold, and to the other number
          # when it does, and rt_mul32 is not called. The interpreter works the other number out either way, so it is
          # skipped only where working it out changes nothing (Unchanging). True when it was done so.
          def emit_product_by_comparison(node)
            [[node.lhs, node.rhs], [node.rhs, node.lhs]].each do |test, other|
              next unless test.is_a?(Node) && test.kind == :binop && COMPARISONS.include?(test.op)
              next unless other.is_a?(Symbol) || (other.is_a?(Node) && Unchanging.value?(other) { |part| folded(part) })

              nought = fresh("product_nought")
              done = fresh("product_done")
              jump_unless(test, nought)
              value(other)
              @asm.bra(done)
              @asm.label(nought)
              @asm.stz(@asm.direct(R0))
              @asm.stz(@asm.direct(R0 + 2))
              @asm.label(done)
              return true
            end
            false
          end

          # R0 times +number+, a byte, by the console's multiplier: it takes a byte in WRMPYA and a
          # byte in WRMPYB, and eight cycles after WRMPYB is written the 16-bit product is at RDMPYL.
          # WRMPYA keeps its byte, so it is written once, and each of R0's four bytes is multiplied in
          # turn. The low 32 bits of the product are those four products added a byte apart, the way
          # it is done on paper; what carries past the top is dropped, as Int32 drops it, so the sign
          # takes care of itself.
          #
          # Bytes 1 and 3 are multiplied first, into R1, so that the products of bytes 0 and 2 can go
          # straight into R0's halves once their own bytes are read. Byte 1's product is then added a
          # byte up, across R0's middle two bytes, and byte 3's low byte into the top with the carry.
          def emit_product_by_byte_of_r0(number)
            h = Console::SNESHardware
            multiply = lambda do |byte|
              @asm.lda(@asm.direct(R0 + byte))
              @asm.sta(@asm.abs(h::WRMPYB))
              4.times { @asm.nop } # the eight cycles the multiplier takes
            end
            @asm.sep(0x20)
            @asm.lda(number)
            @asm.sta(@asm.abs(h::WRMPYA))
            multiply.call(1)
            @asm.ldx(@asm.abs(h::RDMPYL))
            @asm.stx(@asm.direct(R1))
            multiply.call(3)
            @asm.lda(@asm.abs(h::RDMPYL))
            @asm.sta(@asm.direct(R1 + 2))
            multiply.call(0)
            @asm.ldx(@asm.abs(h::RDMPYL))
            @asm.stx(@asm.direct(R0))
            multiply.call(2)
            @asm.ldx(@asm.abs(h::RDMPYL))
            @asm.stx(@asm.direct(R0 + 2))
            @asm.rep(0x20)
            @asm.clc
            @asm.lda(@asm.direct(R0 + 1))
            @asm.adc(@asm.direct(R1))
            @asm.sta(@asm.direct(R0 + 1))
            @asm.sep(0x20)
            @asm.lda(@asm.direct(R0 + 3))
            @asm.adc(@asm.direct(R1 + 2))
            @asm.sta(@asm.direct(R0 + 3))
            @asm.rep(0x20)
          end

          # A shift whose count is a number written in the program, written in place
          # (#emit_shift_left_of_r0). True when it was done so.
          def emit_shift_by_written_count(node)
            count = folded(node.rhs)
            return false unless count

            lhs = node.lhs
            if node.op == :>>
              lhs, count = shift_right_of_shift_right(lhs, count)
              return true if count.between?(8, 30) && emit_shift_right_from_place(lhs, count)
            end
            value(lhs)
            node.op == :<< ? emit_shift_left_of_r0(count) : emit_shift_right_of_r0(count)
            true
          end

          # `(x >> 8) >> 4` is `x >> 12`: an arithmetic shift right twice is one shift by the two
          # counts together, and a count of 31 or more leaves only the sign either way. The number
          # shifted and the count, for +lhs+ shifted right +count+.
          def shift_right_of_shift_right(lhs, count)
            while count.between?(0, 30) && binop?(lhs, :>>) && (inner = folded(lhs.rhs))&.between?(0, 30)
              lhs = lhs.lhs
              count = [count + inner, 31].min
            end
            [lhs, count]
          end

          # A shift right by a byte or more of a number that is kept somewhere — a variable, or a
          # word slot of a list — is read from that place a byte or more along, where the number's
          # higher bytes already are: `x >> 8`'s low half is x's bytes 1 and 2, read as one word,
          # and its high half is byte 3 with the sign above it. That skips copying x into R0 only to
          # move it down a byte there. What is left of the count past the bytes is turned as
          # #emit_shift_right_of_r0 turns it. True when it was done so.
          def emit_shift_right_from_place(lhs, count)
            read = place_reader(lhs)
            return false unless read

            low = @asm.direct(R0)
            high = @asm.direct(R0 + 2)
            case count / 8
            when 1
              @asm.lda(read.call(1))
              @asm.sta(low)
              emit_top_byte_widened(read, high)
            when 2
              @asm.lda(read.call(2))
              @asm.sta(low)
              emit_sign_word(read, high)
            else
              emit_top_byte_widened(read, low)
              emit_sign_word(read, high)
            end
            emit_shift_right_of_r0(count % 8)
            true
          end

          # Where the four bytes of +node+ are read, a byte along at a time: a block taking how many
          # bytes along and giving the operand there, for a variable or a word slot of a list (its
          # slot found into X first); nil for anything else.
          def place_reader(node)
            name = variable_named(node)
            if name && !folded(node) && !half_variable?(name)
              at = place_of(name)
              return ->(along) { at_place(at + along) }
            end
            return unless node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name)

            place, _capacity, width = list_placed(node)
            return unless width == 4

            emit_slot_into_x(place, list_slots(node).stride, index_halves(node.index), checked: !index_inside_full_list?(node.name, node.index))
            ->(along) { @asm.long_x(list_slots(node).base + along) }
          end

          # The number's top byte, with its sign above it, into the word +to+.
          def emit_top_byte_widened(read, to)
            done = fresh("top_byte_signed")
            @asm.lda(read.call(2))
            @asm.xba # byte 3 down to the low byte
            @asm.and_a(0x00FF)
            @asm.cmp(0x0080)
            @asm.bcc(done)
            @asm.ora(0xFF00)
            @asm.label(done)
            @asm.sta(to)
          end

          # Every bit of the word +to+ the number's sign: all ones below nought, else nought.
          def emit_sign_word(read, to)
            done = fresh("sign_word")
            @asm.lda(read.call(2))
            @asm.and_a(0x8000)
            @asm.beq(done)
            @asm.lda(0xFFFF)
            @asm.label(done)
            @asm.sta(to)
          end

          # `&`, `|` and `^`, a half at a time, each half read from where it is: a variable's own
          # place, or a number written in the program, without copying it into R0 first. A half
          # that a written number leaves as it was is only moved, and one it decides whatever the
          # other half is is stored as it is, so `item & 0xFFFF` keeps the low half and is one STZ
          # for the high one, where every half worked out is a load, a sum and a store.
          #
          # The three are the same either way round, so the side that needs nothing worked out, and
          # of two such the written number, is taken as the right.
          def emit_bitwise_halves(node, into = r0_halves)
            first = node.lhs
            left = operand_halves(node.lhs)
            right = operand_halves(node.rhs)
            if left && (!right || (written_half(left.first) && !written_half(right.first)))
              first = node.rhs
              left, right = right, left
            end
            return emit_bitwise_worked_out(node, into) unless right

            unless left
              value(first)
              left = r0_halves
            end
            2.times do |i|
              to = into[i]
              written = written_half(right[i])
              if written && written == HALF_WRITTEN[node.op]
                store_half(written, to)
              elsif written && written == HALF_KEPT[node.op]
                next if left[i] == to

                @asm.lda(left[i])
                @asm.sta(to)
              else
                @asm.lda(left[i])
                emit_half_sum(node.op, right[i])
                @asm.sta(to)
              end
            end
          end

          # A bitwise sum whose two sides both have to be worked out (#with_both_halves).
          def emit_bitwise_worked_out(node, into)
            with_both_halves(node.lhs, node.rhs) do |lefts, halves|
              2.times do |i|
                @asm.lda(lefts[i])
                emit_half_sum(node.op, halves[i])
                @asm.sta(into[i])
              end
            end
          end

          # The number an operand half is, when it is one written in the program; nil otherwise.
          def written_half(half) = (half.value if half&.mode == :imm && half.value.is_a?(Integer))

          # A nought goes in with STZ where it can; the 65816 has no STZ to a long address, so a
          # variable kept past $FFFF takes its nought through A, as store_number does.
          def store_half(number, to)
            return @asm.stz(to) if number.zero? && to.mode != :long

            @asm.lda(number)
            @asm.sta(to)
          end

          # A runtime routine taking +args+ in R0, R1, R2... Each that needs working out is worked out
          # in order and pushed, then they are pulled into their working numbers, the last first; then
          # the ones that are only a number or a variable are put in theirs.
          #
          # When each is only read into R0 — a list's item at an index already somewhere, or where a
          # label is — none of them can touch another's working number, so each is read and moved
          # straight into its own: four instructions, where the stack took two pushes and two pulls
          # with a store after each. A pool's sprite is placed every pass with three such reads.
          # They are still read in order, so the one a game stops at is the interpreter's; a label's
          # place, which can never stop the game, is the one left to the end when it goes in R0.
          def runtime_call(name, args)
            worked = args.each_index.reject { |i| operand_halves(args[i]) }
            if (order = order_read_alone(args, worked))
              order.each do |i|
                value(args[i])
                next if i.zero?

                2.times do |half|
                  @asm.lda(@asm.direct(R0 + (2 * half)))
                  @asm.sta(@asm.direct(Memory.register(i) + (2 * half)))
                end
              end
            else
              worked.each { |i| push_value(args[i]) }
              worked.reverse_each { |i| pull_into(Memory.register(i)) }
            end
            args.each_with_index do |arg, i|
              next if worked.include?(i)

              halves = operand_halves(arg)
              2.times do |half|
                if halves[half].mode == :imm && halves[half].value.zero?
                  @asm.stz(@asm.direct(Memory.register(i) + (2 * half)))
                else
                  @asm.lda(halves[half])
                  @asm.sta(@asm.direct(Memory.register(i) + (2 * half)))
                end
              end
            end
            call_routine(name)
          end

          # The order to read +worked+ (indexes into +args+) in when each is only read into R0
          # (#runtime_call), R0's own last; or nil when one is not, or when R0's own could stop
          # the game and so cannot be moved behind the others. One alone can be anything: nothing
          # else worked out is waiting in a working number for it to overwrite.
          def order_read_alone(args, worked)
            return worked if worked.size == 1
            return unless worked.size > 1 && worked.all? { |i| read_alone_into_r0?(args[i]) }
            return worked unless worked.first.zero?
            return unless args[0].is_a?(LongAddress)

            worked.drop(1) + [0]
          end

          # Whether working +node+ out writes no working number but R0: where a label is, or an
          # item of a list nothing takes from the front, at an index that is a variable or a number.
          def read_alone_into_r0?(node)
            return true if node.is_a?(LongAddress)

            node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name) &&
              !index_in_place(node.index).nil?
          end
        end
      end
    end
  end
end
