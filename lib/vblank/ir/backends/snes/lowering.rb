# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # ONE PROGRAM, LOWERED STRAIGHT TO 65816 MACHINE CODE: the Super Nintendo's peer of the GBA
        # and Game Boy Color lowerings. It walks the IR with a table naming the method for each kind
        # of statement and each kind of value (the interpreter's own shape, Reference), and emits the
        # instructions through the assembler (W65816), calling the runtime (SNES::Runtime) for what
        # is too long to write in place.
        #
        # HOW A NUMBER IS WORKED OUT. Every value leaves its answer in R0, the first working number on
        # the direct page (Memory.register), its low half first. A sum of two works the left-hand side
        # out into R0 and takes the right-hand side from where it already is — a number written in
        # the program is part of the instruction, a variable is read where it lives — so `x + 1` is
        # six instructions and no call. A right-hand side that has to be worked out first is worked
        # out, pushed on the stack, and pulled into R1 once the left-hand side is in R0. A runtime
        # routine taking several numbers has them in R0, R1, R2... Nothing is kept in a register from
        # one statement to the next, so a statement never has to know what came before it. A and the
        # index registers are 16 bits wide throughout.
        #
        # WHERE THINGS LIVE. The game's variables, and each routine's own numbers — a loop's count, a
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

          # EVERY KIND THIS LOWERING WRITES: its own, each by a method called by name in
          # #emit_statement and #value_of_kind, and each part's (Picture, Paint and the rest, and the
          # loops and tests every cartridge lowering shares, ControlFlow), which each part writes in a
          # case of its own. A declaration writes nothing where it is. Read by
          # test_snes_kind_coverage.rb.
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp call call_one_of
            halt wait_vblank list_new list_push list_drop list_set list_fill list_copy list_sort
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

          VALUE_KINDS = (%i[
            int var_ref binop neg bit_not absolute clamped mul_fix div_fix shift_right held pressed list_get
            list_len table_get timer_ticks chance local_player
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
            when :list_get then value_of_list_get(node)
            when :list_len then value_of_list_len(node)
            when :table_get then value_of_table_get(node)
            when :timer_ticks then value_of_timer_ticks(node)
            when :chance then value_of_chance(node)
            when :local_player then value_of_local_player(node)
            when *Collision::VALUE_KINDS then value_of_collision_kind(node)
            when *Saving::VALUE_KINDS then value_of_saving_kind(node)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # EVERY KIND THIS LOWERING CANNOT MAKE YET, by what it is part of. A kind leaves the list the
          # day the Super Nintendo does it; test_snes_kind_coverage.rb holds the list and the tables
          # above to every kind there is.
          NOT_LOWERED_YET = Ractor.make_shareable({
                                                    "the picture" => %i[show_picture_group data_byte],
                                                    "sprite tiles the game loads" => %i[load_sprite_tiles],
                                                    "telling which controllers are connected" => %i[players_connected]
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

          # WHAT THE SUPER NINTENDO'S LOWERING ALONE WORKS OUT FROM THE PROGRAM, once a build for all
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
                                                                                 stacking: @cache.stacking, **choices)
            end
          end

          # Where each of the game's variables went, by its name, and each of its lists — [its place,
          # its capacity, the bytes a slot, its name] — once #sections has placed them; the label of
          # the routine the runtime runs at each frame boundary, or nil for a game with no timers; and
          # each routine's section, by its label, beside what that routine is to the author.
          attr_reader :variables, :lists, :frame_begins, :section_routines

          # +sprite_squares+ draws sprites' squares of 16×16 as one row of the table each (Art).
          # +screen_colors+ has each scene bring its own background colours in, and +sprite_colors+ its
          # own sprite colours, +sprite_tiles+ its own sprite tiles, and +background_tiles+ its own
          # background tiles (Art). +one_sprite_tile_set+ makes one set of a sprite's pictures for
          # all the lists of colours it wears (Picture#palette_in_places). +chip+ is a cartridge
          # with a Super FX, which runs the routines marked for it (Chip). +cache+ is what the build
          # works out from the program once for all its tries (BuildCache), its background pictures'
          # pixels among it (Art::TileMemo).
          def initialize(program, memory:, sprite_squares: true, screen_colors: false, sprite_colors: false, sprite_tiles: false,
                         background_tiles: false, small_sprite_scenes: [], one_sprite_tile_set: false, chip: false,
                         cache: BuildCache.for(SNES, program))
            @program = program
            @cache = cache
            @tile_memo = cache.facts.tile_memo
            @one_sprite_tile_set = one_sprite_tile_set
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
            @variables = {}
            @locals = {} # a routine's own numbers, by the name the lowering gave each
            @starts = [] # [address, value] for a place that does not start at nought
            @routine_tables = {} # a list of routines a call picks from by number -> its table's label
            @section_routines = {}
            @cuts = RoutineCuts.for(self, cache)
            prepare_picture
            prepare_paint
            prepare_collision
            prepare_sound
            prepare_chip(chip)
          end

          # The game's code, as sections for the Linker: its data, every routine a run can reach, and
          # the program itself.
          def sections
            Backends.refuse_start_file_on_cartridge!(@program, @plan.console, LoweringError)
            refuse_unlowered_kinds!
            refuse_what_snes_lacks!
            @plan.refuse_routines_that_call_themselves!
            refuse_what_chip_cannot_run!
            refuse_unmade_picture!
            refuse_unsupported_save_memory!
            assign_background_layers unless painted?
            make_sprite_art
            make_shared_background_colors
            reserve_patches
            # ...and the ones a game loop keeps of its own in the console's order (IR::Frames::ConsoleLoop).
            loops = @plan.game_loops.flat_map { |node| console_loop(node).variables }
            place_variables(Reach.variables(@program) | loops)
            place_chip_lists
            @declared_lists.each_value do |node|
              width = LoweringPlan::SLOT_BYTES.fetch(node.width)
              place = chip_list_place(node.name) ||
                      @memory.reserve_far("the list #{node.name.inspect}", Runtime::Lists::HEADER + (node.capacity * width))
              @lists[node.name] = [place, node.capacity, width, node.name.to_s]
            end
            @scene = keep_local(:scene, start: -1) unless @scenes.empty?
            keep_timer_numbers
            keep_corner_notes
            keep_background_color_choices
            keep_sprite_color_choices
            keep_scene_tiles_up
            keep_loop_running
            keep_column_numbers
            keep_order_tables
            make_chip_code
            routines = @called.flat_map do |name|
              next [chip_routine_section(name)] if on_chip?(name)

              @lowering_scene = @scenes.key?(name) ? name : nil
              routines_fitting(self.class.routine_label(name), @funcs.fetch(name).children, routine: routine_said(name))
            end
            timers = timer_sections
            @lowering_scene = nil
            main = routines_fitting(MAIN, @program.children, routine: "the game loop")
            placings = sprite_placing_sections
            columns = column_sections
            [data_section, *table_sections, *routines, *timers, *main, *placings, *columns, *chip_sections]
          end

          # Whether the game has a division only a runtime routine can do (Runtime::Int32), once
          # #sections has lowered it.
          def divides? = @divides || false

          # Whether the game moves a whole list to or from save memory, so its runtime carries the
          # routines that do it as a block (Runtime::Saving#emit_list_moves).
          def moves_lists_to_save? = SaveListMoves.moved_in?(@program)

          # How many bytes +list+ comes to, made on copies of what the lowering holds and thrown away
          # (LoweringState#on_copies).
          def bytes_of(list)
            LOWERING_STATE.on_copies(self) do
              @asm = W65816.new("measuring", holds: ROUTINES)
              @routine = "measuring"
              @labels = 0
              list.each { |node| statement(node) }
              @asm.here
            end
          end

          private

          # --- refusals ---

          # What a run can reach and this lowering cannot make, refused by name before anything is
          # made: a step that only means something on the Advance, and one the Super Nintendo build
          # does not make yet. A step in a routine nothing calls never runs, and is not refused.
          def refuse_unlowered_kinds!
            @plan.refuse_hardware_only_kinds!
            @plan.refuse_kinds_not_made_yet!(NOT_LOWERED_YET, NotMadeYet)
            @plan.refuse_unmade_followed_lists!(NotMadeYet)
          end

          # What a Super Nintendo cannot do at all, as a game's build refuses it
          # (LoweringPlan#refuse_what_console_lacks!), then the see-through amounts it cannot mix:
          # an even half is made, and Picture#refuse_see_through_amounts! says in its own words why
          # another is not.
          def refuse_what_snes_lacks!
            @plan.refuse_what_console_lacks!
            refuse_see_through_amounts!
          end

          # --- the data ---

          # The places that do not start at nought, each list's place, capacity and slot (the
          # runtime's start reads them), and the tables of routines a call picks from by number.
          def data_section
            asm = W65816.new("game data", holds: DATA)
            asm.label("game_starts")
            @starts.each do |address, value|
              asm.data_words(address, value & 0xFFFF, (value >> 16) & 0xFFFF)
            end
            asm.data_words(0)
            asm.label("game_lists")
            @lists.each_value do |place, capacity, width, _|
              asm.data_bytes(place & 0xFF, (place >> 8) & 0xFF, place >> 16)
              asm.data_words(capacity, width)
            end
            asm.data_bytes(0, 0, 0)
            @routine_tables.each do |targets, label|
              asm.label(label)
              asm.data_longs(targets.map { |name| self.class.routine_label(name) })
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
          # It goes in the first 8K while that has more room than the runtime still asks for after
          # the lowering (NEAR_BYTES_LAST), and past it after that, as the variables named least do.
          def keep_local(what, start: 0)
            name = DerivedNames.local_number_name(@routine, what, @locals.length + 1)
            label = "the game's number #{name}"
            @locals[name] = @memory.near_bytes_left >= NEAR_BYTES_LAST + 4 ? @memory.reserve(label, 4) : @memory.reserve_far(label, 4)
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          # What the lowering reads and writes a number at: a variable in the first 8K, which every
          # bank the code runs in can see, or one past it, named by its whole address. That costs a
          # byte more and a cycle more each time.
          def at_place(at) = at > 0xFFFF ? @asm.long(at) : @asm.abs(at)

          # Bytes of the first 8K left for what is kept after the variables: the routines' own
          # numbers, and what the runtime asks for as it is written.
          NEAR_BYTES_KEPT = 0x400

          # Bytes of the first 8K left for what the runtime asks for as it is written, after the
          # lowering: a routine's own numbers go past it rather than into these.
          NEAR_BYTES_LAST = 0x80

          # EVERY VARIABLE A PLACE, THE ONES USED MOST IN THE FIRST 8K OF WORK RAM. That is the part
          # the code reaches quickly, and a game with many numbers can want more of it than there
          # is. The ones it names least go past it, in the rest of the 128K: the game's own and the
          # ones the framework keeps for it (`__approach_2`) alike, since the lowering reads and
          # writes every one by the address it was given. A game that fits is laid out as it always
          # was. Only the variables the runtime reads by a 16-bit address stay near (NEAR_ONLY).
          def place_variables(names)
            far = variables_kept_far(names)
            names.each do |name|
              label = "the variable #{name.inspect}"
              @variables[name] = far.include?(name) ? @memory.reserve_far(label, 4) : @memory.reserve(label, 4)
            end
          end

          # The variables the runtime's own code reads by a 16-bit address: the music's volume,
          # which the tune's player reads (Runtime::Music#emit_level).
          NEAR_ONLY = [IR::Tunes::LEVEL].freeze

          # The variables that go past the first 8K, the ones named least. Before any variable goes far the runtime's tables do (Memory#reserve_table): the runtime
          # reads those a few times a frame, and the game's code reads its variables all the time. So
          # a game that does not fit with the tables near is built again with them far (SNES#build).
          def variables_kept_far(names)
            over = ((names.length * 4) - (@memory.near_bytes_left - NEAR_BYTES_KEPT)).ceildiv(4)
            return [] unless over.positive?
            raise @memory.near_full("the variable #{names.last.inspect}", 4) unless @memory.far_tables?

            uses = @program.walk.each_with_object(Hash.new(0)) do |node, count|
              named = node.kind == :var_ref ? node.name : (node.var if %i[set add sub].include?(node.kind))
              count[named] += 1 if named
            end
            (names - NEAR_ONLY).min_by(over) { |name| uses[name] }
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
                     SpriteNames, Music, W65816, RoutineCuts::PartCall, LoweringPlan, ChipCode],
            unchanged: %i[@cuts @cache @tile_memo @keyed_sorts @keys_by_place]
          )

          # --- statements ---

          def statement(node)
            return call_routine(node.label) if node.is_a?(RoutineCuts::PartCall)

            emit_statement(node)
          end

          def emit_nothing(_node) = nil
          def emit_children(node) = node.children.each { |child| statement(child) }

          # R0 into the variable +name+.
          def store(name)
            at = place_of(name)
            @asm.lda(@asm.direct(R0))
            @asm.sta(at_place(at))
            @asm.lda(@asm.direct(R0 + 2))
            @asm.sta(at_place(at + 2))
          end

          # A variable set to itself changes nothing, so nothing is made for one.
          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            known = folded(node.value)
            return store_number(place_of(node.var), known) if known
            return copy_variable(node.value, node.var) if variable_named(node.value)
            return emit_sum_into(node.value, variable_halves(node.var)) if sum_in_halves?(node.value) && !folded(node.value)

            value(node.value)
            store(node.var)
          end

          # Where the variable +name+'s two halves are, as operands.
          def variable_halves(name)
            at = place_of(name)
            [at_place(at), at_place(at + 2)]
          end

          # One variable into another, a half at a time from where it is: four instructions, where
          # working it out into R0 first and storing it from there is eight. A pool's walk does this
          # several times for each thing it visits.
          def copy_variable(from, name)
            halves = operand_halves(from)
            at = place_of(name)
            2.times do |i|
              @asm.lda(halves[i])
              @asm.sta(at_place(at + (2 * i)))
            end
          end

          # A number written in the program, straight into the variable at +at+.
          def store_number(at, number)
            number &= 0xFFFF_FFFF
            [number & 0xFFFF, number >> 16].each_with_index do |half, i|
              if half.zero? && at <= 0xFFFF # nothing stores a nought straight to a whole address
                @asm.stz(@asm.abs(at + (2 * i)))
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
          def emit_sub(node) = emit_sum(node.var, :-, node.operand)

          # `x = x + n` and `x = x - n`, added where x is when n is a number written in the program or
          # a variable: six instructions and no call.
          #
          # When n has to be worked out it is worked out into R0 first and added from there: x is
          # only read and written by the sum itself, so working n out first reads the same x.
          def emit_sum(name, op, operand)
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

          def fresh_label(what) = fresh(what)
          def place_label(label) = @asm.label(label)
          def jump(label) = @asm.brl(label)
          def emit_value(operand) = value(operand)
          def emit_store(name) = store(name)
          def emit_store_zero(name) = store_number(place_of(name), 0)
          def emit_copy_variable(from, to) = copy_variable(from, to)
          def emit_increment(name) = emit_sum(name, :+, Build.int(1))
          def loop_statements(node) = children_of(node).first
          def game_loops = @plan.game_loops
          def loop_form = @plan.loop_form

          def console_loop(node) = @plan.console_loop(node)

          # Is +node+ one of the boundary's writes a game loop places at the end of its pass, or in
          # one (IR::Frames::ConsoleLoop#placed)?
          def placed_at_pass_end?(node)
            @placed_at_pass_end ||= @plan.game_loops.flat_map { |loop_node| console_loop(loop_node).placed.flat_map { |write| write.walk.to_a } }
                                         .to_h { |write| [write.object_id, true] }
            @placed_at_pass_end.key?(node.object_id)
          end

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @funcs.key?(node.target)

            call_routine(self.class.routine_label(node.target))
          end

          # Reference#exec_call_one_of: the number worked out once, and a number naming no routine of
          # the list — below nought or past its end — calls nothing. Compared as a number that cannot
          # be negative, -1 is the biggest there is, so one test guards both ends. The routine is
          # reached through a table of their long addresses: its address pushed as RTL would find a
          # return address (one less, bank first), and RTL taken to it.
          def emit_call_one_of(node)
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
            emit_bends
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
            return list_call("rt_list_empty", node) unless node.full_of

            list_call("rt_list_at_capacity", node)
            list_call("rt_list_fill", node, Build.int(0), Build.int(node.capacity), Build.int(node.full_of))
          end
          def emit_list_push(node) = list_call("rt_list_push", node, node.value)
          def emit_list_drop(node) = list_call("rt_list_drop", node, Build.int(node.from == :front ? 1 : 0))
          def emit_list_fill(node) = list_call("rt_list_fill", node, node.from, node.count, node.value)
          # How many a list holds is a word of its header, read where it is: three instructions, where
          # the runtime's call takes the list's place handed over, the jump there and back, and the
          # header found from the place. A pool asks it of its retired things at the end of every walk.
          def value_of_list_len(node)
            @asm.lda(@asm.long(list_place(node), Runtime::Lists::LENGTH))
            @asm.sta(@asm.direct(R0))
            @asm.stz(@asm.direct(R0 + 2))
          end

          # A LIST NOTHING TAKES FROM THE FRONT keeps its first item in its first slot for good, so an
          # item's slot is its index, and its place is known here: one load with X as the index, past
          # one test that the index is inside the list. The runtime's way finds the place from the
          # list's header, which takes as long as ten sums, and a game walking a map held in a list
          # does this many times a pass.
          def value_of_list_get(node)
            return list_call("rt_list_get", node, node.index) if front_dropped_lists.include?(node.name)

            place, _capacity, width = list_placed(node)
            slot = fixed_slot_address(node, place, width)
            return emit_read_slot_at_x(slot, width, x: false) if slot

            emit_slot_into_x(place, width, index_halves(node.index), checked: !index_inside_full_list?(node.name, node.index))
            emit_read_slot_at_x(place + Runtime::Lists::HEADER, width)
          end

          # Where the slot is, when the index is a number written in the program that is always
          # inside the list (#index_inside_full_list?): the read or write then names the slot
          # itself, with no index worked out at all. Nil otherwise.
          def fixed_slot_address(node, place, width)
            number = folded(node.index)
            return nil unless number && index_inside_full_list?(node.name, node.index)

            place + Runtime::Lists::HEADER + (number * width)
          end

          # Where the two halves of +node+ are when it reads a whole-word slot at a fixed address
          # (#fixed_slot_address), so a copy from one word slot to another is two loads and two
          # stores; nil for anything else.
          def fixed_word_slot_halves(node)
            return nil unless node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name)

            place, _capacity, width = list_placed(node)
            slot = width == 4 && fixed_slot_address(node, place, width)
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

            place, _capacity, width = list_placed(node)
            halves = operand_halves(node.value)
            slot = fixed_slot_address(node, place, width)
            halves ||= fixed_word_slot_halves(node.value) if slot && width == 4
            if slot
              # A word's sum is written straight into its slot, a half at a time.
              if !halves && width == 4 && sum_in_halves?(node.value) && %i[+ -].include?(node.value.op)
                return emit_sum_into(node.value, [@asm.long(slot), @asm.long(slot, 2)])
              end

              unless halves
                value(node.value)
                halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
              end
              return emit_write_slot_at_x(slot, width, halves, x: false)
            end

            index = operand_halves(node.index)
            checked = !index_inside_full_list?(node.name, node.index)
            if halves
              emit_slot_into_x(place, width, index_halves(node.index), checked: checked)
            elsif index
              value(node.value)
              emit_slot_into_x(place, width, index, checked: checked)
              halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
            else
              push_value(node.index)
              value(node.value)
              pull_into(R1)
              emit_slot_into_x(place, width, [@asm.direct(R1), @asm.direct(R1 + 2)], checked: checked)
              halves = [@asm.direct(R0), @asm.direct(R0 + 2)]
            end
            emit_write_slot_at_x(place + Runtime::Lists::HEADER, width, halves)
          end

          # Where the two halves of a list's index are: where a variable or a written number already
          # is, or R0 once it is worked out.
          def index_halves(index)
            halves = operand_halves(index)
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

          # AN INDEX THAT CANNOT FALL OUTSIDE ITS LIST. A list made full and never made longer or
          # shorter holds its capacity for good, so a number written in the program below that
          # capacity is always inside it: a pool's sprite reading its place in the order, a draw
          # order setting the number of each of its things. And a pool knows its slots are in its
          # lists: a field of the thing a walk is on, read or written in `pool.each` or in a routine
          # of the pool, is a list of the pool's own at a variable the pool keeps a slot in
          # (DSL::Pool::SLOT_PARTS), each made full when the game starts. So the test that the
          # index is inside the list, five instructions on every read, can never fail there and is
          # left out. Every other list read or write keeps it: one ever made longer or shorter, an
          # index worked out, or another pool's slot.
          def index_inside_full_list?(list, index)
            capacity = full_length_lists[list]
            return false unless capacity

            number = folded(index)
            return number.between?(0, capacity - 1) if number

            pool = DSL::Pool.owner_of_list(list)
            var = variable_named(index)
            !pool.nil? && !var.nil? && DSL::Pool.walked_by(var) == pool
          end

          # The lists made full of one number and never made longer or shorter after, so each holds
          # its capacity for good, by name, with that capacity (the least, if made twice).
          def full_length_lists
            @full_length_lists ||= begin
              resized = @reachable.filter_map do |node|
                node.name if %i[list_push list_drop list_fill list_copy save_load_list].include?(node.kind) ||
                             (node.kind == :list_new && !node.full_of)
              end
              made = @reachable.select { |node| node.kind == :list_new && node.full_of && !resized.include?(node.name) }
              made.group_by(&:name).transform_values { |nodes| nodes.map(&:capacity).min }
            end
          end

          # X at how far into its slots the item the number in +index+ (its two halves) names is. An
          # index outside the list is handed to the runtime, in R0 or R1, which stops the game in the
          # interpreter's words and never returns. Without +checked+, the index is known to be inside
          # (#index_inside_full_list?).
          def emit_slot_into_x(place, width, index, checked: true)
            unless checked
              @asm.lda(index[0])
              (width - 1).bit_length.times { @asm.asl }
              return @asm.tax
            end

            inside = fresh("inside_the_list")
            out = fresh("outside_the_list")
            @asm.lda(index[1])
            @asm.bne(out)
            @asm.lda(index[0])
            @asm.cmp(@asm.long(place, Runtime::Lists::LENGTH))
            @asm.bcc(inside)
            @asm.label(out)
            outside = index.first == @asm.direct(R0) ? "rt_list_outside_from_r0" : "rt_list_outside"
            unless [@asm.direct(R0), @asm.direct(R1)].include?(index.first)
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

          # R0 = the slot at +slots+ plus X. A slot narrower than a word reads back with its top bit
          # as the sign (Reference::ListValue#wrap_to_width).
          def emit_read_slot_at_x(slots, width, x: true)
            if width == 4
              @asm.lda(slot_operand(slots, 2, x))
              @asm.sta(@asm.direct(R0 + 2))
              @asm.lda(slot_operand(slots, 0, x))
              return @asm.sta(@asm.direct(R0))
            end

            read = fresh("slot_read")
            @asm.stz(@asm.direct(R0 + 2))
            @asm.lda(slot_operand(slots, 0, x))
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

          # A LIST PUT IN ORDER, written in place (Reference#exec_list_sort): an insertion sort over
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
            return emit_keyed_sort(keyed) if keyed

            refuse_ring_sort!(node)
            place, _capacity, width = list_placed(node)
            keys_place, _keys_capacity, key_width = @lists.fetch(node.by) do
              raise LoweringError, "the list #{node.by.inspect} is sorted by and never declared"
            end
            sort = SortPlaces.new(slots: place + Runtime::Lists::HEADER, width: width,
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

          # A SORT WHOSE NUMBERS ARE KEPT BY PLACE IN THE ORDER, the way a draw order's is
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
          # What is left is mostly the numbers themselves, worked out as whole words: eight
          # instructions a thing, the index read among them.
          #
          # THE ORDER IS KEPT IN THESE TABLES, NOT IN THE LIST. Three tables in the first 8K, where a
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
          KeyedSort = Data.define(:order, :keys, :count, :lows, :highs, :places, :entries, :descending) do
            # The operands for the two halves of the number +plus+ bytes into the numbers (two bytes
            # a place), plus X when +x+.
            def number(asm, plus, x: false)
              [lows, highs].map { |at| x ? asm.abs_x(at, plus) : asm.abs(at + plus) }
            end
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
                                    entries: @memory.reserve("the items of #{said}", count * 2))
              @keyed_sorts[node.name] = keyed
              @keys_by_place[node.by] = keyed
            end
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
          # places, then the number into the slot there, a half at a time.
          def emit_key_by_place(node, keyed)
            place = @asm.abs(keyed.places + (folded(node.index) * 2))
            to = keyed.number(@asm, 0, x: true)
            value = node.value
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

          # with_both_halves, also reading a word list's slot at a place written in the program where
          # it is.
          def with_key_halves(left, right, &)
            lefts = operand_halves(left) || fixed_word_slot_halves(left)
            rights = operand_halves(right) || fixed_word_slot_halves(right)
            return yield(lefts, rights) if lefts && rights

            with_both_halves(left, right, &)
          end

          # The sort itself: each place after the first compared with the one before it, and the
          # routine that moves an item back called only for one that has to go.
          def emit_keyed_sort(keyed)
            mover = fresh("sort_move")
            done = fresh("sort_done")
            (1...keyed.count).each do |place|
              stays = fresh("sort_stays")
              emit_keyed_compare(keyed, keyed.number(@asm, place * 2), keyed.number(@asm, (place * 2) - 2))
              @asm.bpl(stays)
              emit_keyed_swap(keyed, place)
              if place > 1
                emit_keyed_compare(keyed, keyed.number(@asm, (place * 2) - 2), keyed.number(@asm, (place * 2) - 4))
                @asm.bpl(stays)
                @asm.ldx((place - 1) * 2)
                @asm.jsr(@asm.abs(mover))
              end
              @asm.label(stays)
            end
            @asm.brl(done)
            emit_keyed_move(keyed, mover)
            @asm.label(done)
          end

          # The item in +place+ and the one before it swapped, at addresses known as the cartridge is
          # built: the step nearly every move is, when two things pass each other. Twenty
          # instructions, about half what the general step takes (#emit_keyed_move).
          def emit_keyed_swap(keyed, place)
            at = place * 2
            [keyed.lows, keyed.highs].each do |table|
              @asm.lda(@asm.abs(table + at))
              @asm.ldy(@asm.abs(table + at - 2))
              @asm.sta(@asm.abs(table + at - 2))
              @asm.sty(@asm.abs(table + at))
            end
            @asm.lda(@asm.abs(keyed.entries + at))
            @asm.ldx(@asm.abs(keyed.entries + at - 2))
            @asm.sta(@asm.abs(keyed.entries + at - 2))
            @asm.stx(@asm.abs(keyed.entries + at))
            @asm.tay
            @asm.lda(at - 2)
            @asm.sta(@asm.abs_y(keyed.places))
            @asm.lda(at)
            @asm.sta(@asm.abs_x(keyed.places))
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
          #   R2  the item, doubled    R3  its number
          def emit_keyed_move(keyed, mover)
            step = fresh("sort_step")
            placed = fresh("sort_placed")
            key = [@asm.direct(SORT_KEY), @asm.direct(SORT_KEY + 2)]
            here = keyed.number(@asm, 0, x: true)
            before = keyed.number(@asm, -2, x: true)
            @asm.label(mover)
            2.times do |half|
              @asm.lda(here[half])
              @asm.sta(key[half])
            end
            @asm.lda(@asm.abs_x(keyed.entries))
            @asm.sta(@asm.direct(SORT_ITEM))

            @asm.label(step)
            2.times do |half|
              @asm.lda(before[half])
              @asm.sta(here[half])
            end
            @asm.lda(@asm.abs_x(keyed.entries, -2))
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
            @asm.lda(@asm.direct(SORT_ITEM))
            emit_item_placed(keyed)
            @asm.rts
          end

          # The item doubled in A put in the place X names, in the table of items and the table of
          # places.
          def emit_item_placed(keyed)
            @asm.sta(@asm.abs_x(keyed.entries))
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

          # A COMPARISON'S ANSWER TESTED AGAINST 1 OR 0 — `(2 < count) == 1`, which is how a pool's
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

          # The two sides of a comparison compared, and the branch that is taken when it does NOT hold.
          #
          # Equal or not: the low halves compared and, when they match, the high halves; the zero flag
          # gives the answer. Less or more: the left subtracted from the right or the right from the left, the low
          # halves with CMP and the high halves with SBC and the borrow from the first, which leaves
          # the sign of the difference in the negative flag — unless the subtraction overflowed, in
          # which case the sign came out the wrong way round and is flipped back.
          def compare(node)
            op = node.op
            return compare_narrow_slot(op, *narrow_slot_and_number(node)) if narrow_slot_and_number(node)

            left, right = %i[> <=].include?(op) ? [node.rhs, node.lhs] : [node.lhs, node.rhs]
            with_both_halves(left, right) do |lefts, halves|
              if %i[== !=].include?(op)
                differ = fresh("differ")
                @asm.lda(lefts[0])
                @asm.cmp(halves[0])
                @asm.bne(differ)
                @asm.lda(lefts[1])
                @asm.cmp(halves[1])
                @asm.label(differ)
              else
                signed = fresh("signed")
                @asm.lda(lefts[0])
                @asm.cmp(halves[0])
                @asm.lda(lefts[1])
                @asm.sbc(halves[1])
                @asm.bvc(signed)
                @asm.eor(0x8000)
                @asm.label(signed)
              end
            end
            # The negative flag now shows left < right, where for > and <= the two were swapped.
            { :== => :bne, :!= => :beq, :< => :bpl, :> => :bpl, :>= => :bmi, :<= => :bmi }.fetch(op)
          end

          # A BYTE OR HALF SLOT OF A LIST TESTED EQUAL, OR NOT, TO A NUMBER WRITTEN IN THE PROGRAM. A
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
              next unless slot.is_a?(Node) && slot.kind == :list_get && !front_dropped_lists.include?(slot.name)

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
            emit_slot_into_x(place, width, index_halves(slot.index), checked: !index_inside_full_list?(slot.name, slot.index))
            @asm.lda(@asm.long_x(place + Runtime::Lists::HEADER))
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

            with_both_halves(without_added_nought(node.lhs), node.rhs) do |lefts, halves|
              emit_carry_for(node.op)
              2.times do |i|
                @asm.lda(lefts[i])
                emit_half_sum(node.op, halves[i])
                @asm.sta(to[i])
              end
            end
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

          def value_of_absolute(node)
            done = fresh("positive")
            value(node.operand)
            @asm.lda(@asm.direct(R0 + 2))
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

          def value_of_mul_fix(node) = runtime_call("rt_mul_fix", [node.lhs, node.rhs, fraction_bits(node)])
          def value_of_div_fix(node) = runtime_call("rt_div_fix", [node.lhs, node.rhs, fraction_bits(node)])
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
          # any of them for Buttons::ANY. The second controller's are a word of their own, with
          # the same bits, and either controller is the two words together.
          def value_of_held(node) = emit_button_truth(Runtime::Frame::HELD, Runtime::Frame::SECOND_HELD, node)
          def value_of_pressed(node) = emit_button_truth(Runtime::Frame::PRESSED, Runtime::Frame::SECOND_PRESSED, node)

          def emit_button_truth(first, second, node)
            mask = button_truth_mask(node.button)
            nought = fresh("not_down")
            @asm.lda(@asm.abs(@memory[node.player == 2 ? second : first]))
            @asm.ora(@asm.abs(@memory[second])) if node.player == Buttons::ANY
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

          def load_variable(name)
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

            node.name if node.is_a?(Node) && node.kind == :var_ref
          end

          # Where the two halves of +node+ can be read without working anything out: the number itself
          # for one written in the program, the variable's place for a variable; or nil.
          def operand_halves(node)
            known = folded(node)
            return [@asm.imm(known & 0xFFFF), @asm.imm((known >> 16) & 0xFFFF)] if known

            name = variable_named(node)
            return nil unless name

            at = place_of(name)
            [at_place(at), at_place(at + 2)]
          end

          # The left side worked out into R0, and the block handed where the two halves of the right
          # side are: in place when it needs nothing worked out, and otherwise worked out first,
          # pushed, and pulled into R1 once the left side is in R0.
          def with_right_halves(left, right)
            halves = operand_halves(right)
            if halves
              value(left)
              return yield(halves)
            end

            push_value(right)
            value(left)
            pull_into(R1)
            yield [@asm.direct(R1), @asm.direct(R1 + 2)]
          end

          # The block handed where the two halves of each side are. A side that needs nothing worked
          # out is read where it is. When only the right side needs working out, it is worked out
          # into R0 and the left read where it is, with nothing pushed: reading a variable or a
          # written number gives the same before or after, so the order cannot show. Otherwise the
          # left side is worked out into R0 as #with_right_halves has it.
          def with_both_halves(left, right)
            lefts = operand_halves(left)
            rights = operand_halves(right)
            return yield(lefts, rights) if lefts && rights

            in_r0 = [@asm.direct(R0), @asm.direct(R0 + 2)]
            if lefts
              value(right)
              return yield(lefts, in_r0)
            end

            with_right_halves(left, right) { |halves| yield(in_r0, halves) }
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

          # THE CONSOLE DIVIDES 16 BITS BY A BYTE BY ITSELF: a number written to WRDIVL and WRDIVH and a
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

          # A SHIFT BY A NUMBER WRITTEN IN THE PROGRAM is written in place, never as a call of
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

          # A PRODUCT BY A NUMBER WRITTEN IN THE PROGRAM is written in place, never as a call of
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

          # A PRODUCT BY A COMPARISON is the other number while the comparison holds and nought while
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

          # A SHIFT RIGHT BY A BYTE OR MORE OF A NUMBER THAT IS KEPT SOMEWHERE — a variable, or a
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
            if name && !folded(node)
              at = place_of(name)
              return ->(along) { at_place(at + along) }
            end
            return unless node.is_a?(Node) && node.kind == :list_get && !front_dropped_lists.include?(node.name)

            place, _capacity, width = list_placed(node)
            return unless width == 4

            emit_slot_into_x(place, width, index_halves(node.index), checked: !index_inside_full_list?(node.name, node.index))
            ->(along) { @asm.long_x(place + Runtime::Lists::HEADER + along) }
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
          # WHEN EACH IS ONLY READ INTO R0 — a list's item at an index already somewhere, or where a
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
              !operand_halves(node.index).nil?
          end
        end
      end
    end
  end
end
