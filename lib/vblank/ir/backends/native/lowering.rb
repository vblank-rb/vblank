# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # ONE PROGRAM, WRITTEN OUT AS C. Make one per program and ask for #source.
        #
        # The shape follows the interpreter's own (Backends::Reference): a table naming the
        # method for each kind of statement, and one for each kind of value, so the two read
        # side by side and a kind missing from either table is one line to find. A kind this
        # backend cannot write yet is refused by name at the start, rather than half the program
        # being written first.
        #
        # What the generated file holds, top to bottom: the game's variables, every routine, the
        # program itself as rg_game_main (the runtime calls it once, at power-on), and
        # rg_game_dump_state, which a test build uses to print where every variable and list stands.
        class Lowering
          include Picture
          include Sound
          include Saving
          include StartFileFills

          # The operators of a binop, by the rg_int32.h function that does each one.
          OPERATORS = Ractor.make_shareable({
                                              :+ => "rg_add", :- => "rg_sub", :* => "rg_mul",
                                              :/ => "rg_div", :% => "rg_mod",
                                              :& => "rg_and", :| => "rg_or", :^ => "rg_xor",
                                              :<< => "rg_shl", :>> => "rg_shr",
                                              :< => "rg_lt", :<= => "rg_le", :> => "rg_gt",
                                              :>= => "rg_ge", :== => "rg_eq", :!= => "rg_ne",
                                              and: "rg_both", or: "rg_either"
                                            })

          # EVERY KIND THIS LOWERING WRITES, each by a method of its own called by name in #lower and
          # #value_by_kind; read by test_native_kind_coverage.rb and #refuse_unlowered_kinds!. A
          # declaration writes nothing where it is (#lower_nothing).
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp if loop repeat every after call call_one_of
            case halt wait_vblank timer_start timer_stop on_timer set_clock list_new list_push list_drop
            list_set list_fill list_copy list_sort screen clear_screen fill_rect dma_fill_rect draw_rect_at
            pixel draw_text draw_digit inside camera blit blit_pose draw_column_at draw_place fill_face
            save_region restore_region background affine_background scroll_background place_bar box_background
            scroll_rows shade_outside show_light_now set_tile show_map show_held_tiles background_colors
            color_list_holds show_picture_group copy_tiles copy_owed_tiles load_sprite_tiles present_objects
            hide_sprites rumble fade tint pixelate see_through beep enable_sound play_song stop_music
            hold_music play_from_list play_sound_effect play_sample stop_sample wave stop_wave noise save_init
            save_store save_write save_erase
          ] + Nodes.of_role(:declaration)).freeze

          def lower(node)
            case node.kind
            when :program then lower_children(node)
            when :set then lower_set(node)
            when :add then lower_add(node)
            when :sub then lower_sub(node)
            when :copy then lower_copy(node)
            when :negate then lower_negate(node)
            when :abs then lower_abs(node)
            when :negate_abs then lower_negate_abs(node)
            when :clamp then lower_clamp(node)
            when :if then lower_if(node)
            when :loop then lower_loop(node)
            when :repeat then lower_repeat(node)
            when :every then lower_every(node)
            when :after then lower_after(node)
            when :call then lower_call(node)
            when :call_one_of then lower_call_one_of(node)
            when :case then lower_case(node)
            when :halt then lower_halt(node)
            when :wait_vblank then lower_wait_vblank(node)
            when :timer_start then lower_timer_start(node)
            when :timer_stop then lower_timer_stop(node)
            when :on_timer then lower_nothing(node)
            when :set_clock then lower_set_clock(node)
            when :list_new then lower_list_new(node)
            when :list_push then lower_list_push(node)
            when :list_drop then lower_list_drop(node)
            when :list_set then lower_list_set(node)
            when :list_fill then lower_list_fill(node)
            when :list_copy then lower_list_copy(node)
            when :list_sort then lower_list_sort(node)
            when :screen then lower_screen(node)
            when :clear_screen then lower_clear_screen(node)
            when :fill_rect then lower_fill_rect(node)
            when :dma_fill_rect then lower_dma_fill_rect(node)
            when :draw_rect_at then lower_draw_rect_at(node)
            when :pixel then lower_pixel(node)
            when :draw_text then lower_draw_text(node)
            when :draw_digit then lower_draw_digit(node)
            when :inside then lower_inside(node)
            when :camera then lower_camera(node)
            when :blit then lower_blit(node)
            when :blit_pose then lower_blit_pose(node)
            when :draw_column_at then lower_draw_column_at(node)
            when :draw_place then lower_draw_place(node)
            when :fill_face then lower_fill_face(node)
            when :save_region then lower_save_region(node)
            when :restore_region then lower_restore_region(node)
            when :background then lower_background(node)
            when :affine_background then lower_affine_background(node)
            when :scroll_background then lower_scroll_background(node)
            when :place_bar then lower_place_bar(node)
            when :box_background then lower_box_background(node)
            when :scroll_rows then lower_scroll_rows(node)
            when :shade_outside then lower_nothing(node)
            when :show_light_now then lower_show_light_now(node)
            when :set_tile then lower_set_tile(node)
            when :show_map then lower_show_map(node)
            when :show_held_tiles then lower_show_held_tiles(node)
            when :background_colors then lower_background_colors(node)
            when :color_list_holds then lower_color_list_holds(node)
            when :show_picture_group then lower_nothing(node)
            when :copy_tiles then lower_copy_tiles(node)
            when :copy_owed_tiles then lower_copy_owed_tiles(node)
            when :load_sprite_tiles then lower_load_sprite_tiles(node)
            when :present_objects then lower_present_objects(node)
            when :hide_sprites then lower_hide_sprites(node)
            when :rumble then lower_rumble(node)
            when :fade then lower_fade(node)
            when :tint then lower_tint(node)
            when :pixelate then lower_pixelate(node)
            when :see_through then lower_see_through(node)
            when :beep then lower_beep(node)
            when :enable_sound then lower_enable_sound(node)
            when :play_song then lower_play_song(node)
            when :stop_music then lower_stop_music(node)
            when :hold_music then lower_hold_music(node)
            when :play_from_list then lower_play_from_list(node)
            when :play_sound_effect then lower_play_sound_effect(node)
            when :play_sample then lower_play_sample(node)
            when :stop_sample then lower_stop_sample(node)
            when :wave then lower_wave(node)
            when :stop_wave then lower_stop_wave(node)
            when :noise then lower_noise(node)
            when :save_init then lower_save_init(node)
            when :save_store then lower_save_store(node)
            when :save_write then lower_save_write(node)
            when :save_erase then lower_save_erase(node)
            else lower_declaration_or_refuse(node)
            end
          end

          VALUE_KINDS = %i[
            int var_ref binop neg bit_not absolute clamped mul_fix div_fix shift_right held pressed
            players_connected local_player chance table_get data_byte list_get list_len timer_ticks clock
            pixels_overlap save_read save_sum
          ].freeze

          def value_by_kind(node)
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
            when :players_connected then value_of_players_connected(node)
            when :local_player then value_of_local_player(node)
            when :chance then value_of_chance(node)
            when :table_get then value_of_table_get(node)
            when :data_byte then value_of_data_byte(node)
            when :list_get then value_of_list_get(node)
            when :list_len then value_of_list_len(node)
            when :timer_ticks then value_of_timer_ticks(node)
            when :clock then value_of_clock(node)
            when :pixels_overlap then value_of_pixels_overlap(node)
            when :save_read then value_of_save_read(node)
            when :save_sum then value_of_save_sum(node)
            else raise LoweringError, "the native backend has no row for #{node.kind.inspect}"
            end
          end

          # EVERY KIND THIS BACKEND CANNOT WRITE YET, listed rather than found out. Native
          # trails the other two backends, so a kind may be missing here — but only on this list,
          # which test_native_kind_coverage.rb holds against every kind there is. A kind leaves
          # the list the day it joins STATEMENT_KINDS or VALUE_KINDS.
          NOT_LOWERED_YET = Ractor.make_shareable({})

          # How many bytes a slot of a list takes, by the width it was declared with.
          SLOT_BYTES = Ractor.make_shareable({ byte: 1, half: 2, word: 4, nil => 4 })

          # +title+ is the game's name, for the window.
          def initialize(program, title: "VBlank")
            @program = program
            @title = title
            @names = Names.new
            @locals = 0
            @funcs = by_name(program.walk, :func)
            # The bend each background's rows are given: the last one written for it, wherever
            # that is, since it stands from power-on (Reference#collect_definitions), in the
            # order the bends are first written, which is the order they are worked out in. One
            # written for a background the game does not have is never asked for.
            written = by_name(program.walk, :scroll_rows)
            declared = by_name(program.walk, :background)
            @bends = written.select { |name, _| declared.key?(name) }
            # The game's light: the last one written, wherever, since it stands from power-on
            # (Reference#collect_definitions), or nil for a game with none.
            @shade = program.walk.select { |node| node.kind == :shade_outside }.last
            # ...and whether it takes turns with the scenes it is off in, set as each frame ends.
            @switches_shade = @shade && IR::LightScenes.switches?(program)
            # What each timer does when it ticks: its handler, wherever that is written, since it
            # is the timer's from power-on (Nodes::OnTimer.of). And the number the runtime knows
            # each timer by.
            @tick_handlers = Nodes::OnTimer.of(program)
            @timers = timer_numbers
            @called = called_routines
            # Everything a run can reach: the program, every routine it calls, however deep, and
            # what each bend runs as its lines are worked out. A routine nothing calls is left
            # out of the file altogether, so nothing in it (a table it reads, a routine it calls)
            # can leave something declared and unused.
            @reachable = statements_from(program, *@called.map { |name| @funcs.fetch(name) }, *@bends.values,
                                         *@tick_handlers.values)
            @tables = by_name(program.walk, :table)
            @shadings = by_name(program.walk, :shading)
            @data = by_name(program.walk, :data, :bitmap)
            # A list is there, empty, from power-on wherever it is declared (the interpreter
            # gathers them before running), so its storage is the first declaration's.
            @lists = by_name(@reachable.reverse, :list_new)
            @scenes = scene_numbers
            @start_file_fills = [] # what the routine reading the start file writes into the pictures' pixels (StartFileFills)
            prepare_picture
            prepare_sound
          end

          # The program as one C file.
          def source
            refuse_unlowered_kinds!
            Printer.new.print_file(top_level)
          end

          # Every step a run of the program can reach, values inside them included: what is
          # written out, and what is refused when it cannot be. A check that has to answer the same
          # as the lowering about a step in a routine nothing calls asks for this.
          def reachable_steps = @reachable

          # The runtime features (RuntimeFeatures) the program's steps need: all of them, not only
          # the ones a run can reach, because the picture's tables are made from the whole program
          # (Picture#prepare_picture). A background declared in a routine nothing calls is still
          # in them, and a reachable scroll of it still calls the feature's code.
          def runtime_features = @runtime_features ||= RuntimeFeatures.used_by(@program.walk)

          private

          # --- the file ---

          # Only what a run can reach is written: the compiler is told to treat an unused routine
          # or table as a mistake, which it is in C somebody wrote, and a routine nothing calls
          # never runs (the build has already warned about it).
          #
          # The routines are written first, the ones the picture asks the game through among
          # them, because writing them is what finds the art they draw with; the art then goes
          # above them in the file.
          def top_level
            routines = @called.map { |name| C::Function.new(name: routine(name), body: body_of(@funcs.fetch(name))) }
            answers = [see_through_amounts, bend_offsets, work_out_bends, shade_span, shade_amount, timer_ticks,
                       sprites_over_picture_routine]
            main = C::Function.new(name: @names.own("main"), body: [*build_start_file_reads, *power_on, *lower(@program)], exported: true)
            # The routine reading the start file is written once the art is, which fixes how many pixels
            # there are, and before the arrays it asks for are written out.
            tables = constant_arrays
            art = picture_data
            start_file_routines = build_start_file_routines
            [C::Comment.new("Written by VBlank's native backend. Do not edit; build the game again."),
             C::Include.new("rg_int32.h"), C::Include.new("rg_runtime.h"), C::Include.new("rg_list.h"),
             C::Include.new("rg_screen.h"), C::Include.new("rg_sound.h"),
             C::Include.new("rg_save.h"), *RuntimeFeatures.c_headers(runtime_features).map { |header| C::Include.new(header) },
             *variable_names.map { |name| C::Global.new(name: variable(name)) },
             *list_storage,
             *(@scenes.empty? ? [] : [C::Global.new(name: @names.own("scene"), value: -1)]),
             *(loops_ending_passes.empty? ? [] : [C::Global.new(name: running_loop_variable, value: 0)]),
             *held_colors_globals, *sprites_hidden_globals,
             *tables, *art, *@drawing_arrays, title_array, *sound_tables,
             save_memory_table,
             *@called.map { |name| C::Prototype.new(name: routine(name)) }, *build_start_file_prototypes,
             *routine_table_declarations,
             *routines, *answers, main, *start_file_routines,
             C::Function.new(name: @names.own("dump_state"), body: dump_state, exported: true),
             *(@program.several_players? ? [C::Function.new(name: @names.own("mix_seed"), body: mix_seed, exported: true)] : [])]
          end

          # The game's name as a C string. A character outside plain ASCII is written as '?', since
          # what C keeps a character in may not hold more.
          def title_array
            bytes = @title.to_s.each_char.map { |char| char.ord.between?(32, 126) ? char.ord : "?".ord }
            C::ConstArray.new(name: @names.own("title"), type: "char", values: bytes + [0], exported: true)
          end

          # A program that waits for frames shows nothing until its first frame is set up
          # (Reference#run): the console's picture is switched off until then.
          def power_on
            waits = @program.walk.any? { |node| node.kind == :wait_vblank }
            [*(waits ? [eval_call("rg_screen_hold", C::Int.new(1))] : []), *sound_power_on]
          end

          # What a run can reach, as IR::Reach works it out for every lowering: the statements under a
          # root, the routines they name, every routine reached from the program, from what each
          # bend runs and from what each timer does when it ticks, and every variable.
          def statements_under(root) = Reach.statements_under(root)
          def statements_from(*roots) = Reach.statements_from(*roots)
          def routines_named(nodes) = Reach.routines_named(nodes)
          def called_routines = Reach.routines(@program, also: [*@bends.values, *@tick_handlers.values])
          def variable_names = @variable_names ||= (Reach.variables(@program) + loop_variables).uniq

          def by_name(nodes, *kinds) = nodes.select { |node| kinds.include?(node.kind) }.to_h { |node| [node.name, node] }

          # The routine a match played by several machines calls once, after the game has set itself up, to add the
          # match's shared seed (rg_match_seed, nought when the game is played alone) to the game's random
          # numbers: what makes the colours `rand` picks differ from one match to the next and agree within one.
          # A game that never draws one has an empty routine, and a game for one player has none at all, so it
          # builds as it did before matches were played.
          def mix_seed
            stream = Builder::Randomness::RNG_STATE
            return [] unless variable_names.include?(stream)

            [assign(stream, call("rg_add", variable(stream), call("rg_match_seed")))]
          end

          # Every variable and then every list the game keeps, for a test build to print.
          def dump_state
            variable_names.map { |name| eval_call("rg_dump_variable", C::Text.new(name.to_s), variable(name)) } +
              @lists.keys.map { |name| eval_call("rg_dump_list", C::AddressOf.new(list(name))) }
          end

          # The numbers fixed when the program is built that a run reads: tables, and the bytes
          # of data and pictures.
          #
          # A table read from the file the program is handed as it starts is written as its size
          # alone, and filled from the file before the game's first statement (StartFileFills).
          def constant_arrays
            tables_read.map do |table|
              name = @names.of(:table, table.name)
              next C::StartFileArray.new(name: name, type: table_type(table), count: table.entry_count) if table.from_file

              C::ConstArray.new(name: name, type: table_type(table), values: table_entries(table))
            end + @data.values.select { |data| arrays_read.include?(data.name) }.map do |data|
              refuse_picture_from_start_file!(data.name, "a piece of data read a byte at a time")
              bytes = data.kind == :data ? data.bytes : data.pixels
              C::ConstArray.new(name: @names.of(:data, data.name), type: "uint8_t", values: bytes.bytes)
            end
          end

          # The names of the tables and the data a run reads, by an entry or by copying a run of them.
          def arrays_read
            @arrays_read ||= @reachable.filter_map do |node|
              case node.kind
              when :table_get, :data_byte then node.name
              when :list_copy, :load_sprite_tiles then node.table
              end
            end.uniq
          end

          # The tables a run reads.
          def tables_read = @tables.values.select { |table| arrays_read.include?(table.name) }

          # The C type a table's entries are kept in, by the width the game declared and whether
          # they are signed, with the range that type holds.
          TABLE_TYPES = Ractor.make_shareable({ [:byte, true] => ["int8_t", -128..127], [:byte, false] => ["uint8_t", 0..255],
                                                [:half, true] => ["int16_t", -32_768..32_767],
                                                [:half, false] => ["uint16_t", 0..65_535] })

          # Each of those as the number rg_list.h knows it by (RG_TABLE_INT8...).
          TABLE_KEPT_AS = Ractor.make_shareable({ "int8_t" => 0, "uint8_t" => 1, "int16_t" => 2, "uint16_t" => 3, "int32_t" => 4 })

          # A table kept at the width the game declared it, as the cartridge keeps it: a byte or a
          # half, signed or not, and a whole word otherwise. The build has already checked every
          # entry fits; a table built by hand that names no width, or whose entries do not fit the one it
          # names, keeps whole words. Reading an entry widens it back to a whole number, so nothing
          # that reads one changes.
          def table_type(table)
            type, range = TABLE_TYPES[[table.width, table.signed ? true : false]]
            type && table_entries(table).all? { |v| range.cover?(v) } ? type : "int32_t"
          end

          # A table's entries as the whole numbers a game reads.
          def table_entries(table) = table.values.map { |v| Int32.wrap(v) }

          def list_storage
            @lists.values.map do |node|
              C::ListStorage.new(name: list(node.name), items: @names.of(:list, "#{node.name}.items"),
                                 capacity: node.capacity, width: SLOT_BYTES.fetch(node.width), label: node.name.to_s)
            end
          end

          # One array of routines for each list a call-by-number picks from.
          def routine_table_declarations
            calls = @reachable.select { |node| node.kind == :call_one_of }
            calls.map(&:targets).uniq.map do |targets|
              C::FunctionTable.new(name: routine_table_name(targets), functions: targets.map { |name| routine(name) })
            end
          end

          # --- refusing what cannot be written yet ---

          # What a refusal calls the build this lowering makes. JS::Lowering names its own; every
          # refusal is otherwise the same for both.
          def build_name = "the desktop build"

          # What is refused is only what the program can reach: a console-only step in a routine
          # nothing calls never runs, so the game as C plays the same without it, as the
          # interpreter does, which complains of one only when it is reached.
          def refuse_unlowered_kinds!
            hardware = @reachable.map(&:kind).uniq.select { |kind| Portability.hardware_only?(kind) }
            unless hardware.empty?
              raise LoweringError,
                    "this program uses #{hardware.map(&:inspect).join(', ')}, which only means something on " \
                    "the console itself, so #{build_name} cannot make it."
            end

            missing = @reachable.map(&:kind).uniq.reject do |kind|
              STATEMENT_KINDS.include?(kind) || VALUE_KINDS.include?(kind) || %i[else].include?(kind)
            end
            return if missing.empty?

            # Every kind is either written or listed as not yet (test_native_kind_coverage.rb
            # holds that), so a kind on neither is a mistake in this file, not in the game.
            unknown = missing - NOT_LOWERED_YET.values.flatten
            raise LoweringError, "the native backend has no row for #{unknown.map(&:inspect).join(', ')}" unless unknown.empty?

            raise LoweringError,
                  "this program uses #{missing.map(&:inspect).join(', ')}, which #{build_name} " \
                  "cannot make yet (#{NOT_LOWERED_YET.select { |_, kinds| kinds.intersect?(missing) }.keys.join(', ')}). " \
                  "The cartridge build can."
          end

          # --- statements ---

          # Each statement of a body, after where it was written — and, before any statement the
          # interpreter paints an owed rebuild of the picture for, the same painting (see
          # Reference.defers_repaint?, which this asks rather than keeping a copy of the rule).
          def body_of(node) = statements_of(node.children)

          # The same for a list of statements. +order+ is the game loop they are a pass of
          # (IR::Frames::ConsoleLoop), whose writes placed at the end of the pass are lowered as
          # placed there (#wrapped_for_pass_end).
          def statements_of(children, order: nil)
            children.flat_map do |child|
              paint = Reference.defers_repaint?(child) ? [] : [eval_call("rg_screen_paint_owed_rebuild")]
              lowered = lower(child)
              lowered = wrapped_for_pass_end(lowered) if order&.placed?(child)
              [*source_comment(child), *paint, *lowered]
            end
          end

          # +statements+ run as the end of a pass places the frame's scroll and status bars
          # (Reference#exec_in_loop): a background the pass put up still shows from its corner.
          def wrapped_for_pass_end(statements)
            [eval_call("rg_screen_placing_at_pass_end", C::Int.new(1)), *statements,
             eval_call("rg_screen_placing_at_pass_end", C::Int.new(0))]
          end

          # Where in the game a statement was written, for a person reading the C.
          def source_comment(node)
            node.source ? [C::Comment.new(node.source)] : []
          end

          def lower_children(node) = body_of(node)

          def lower_nothing(_node) = []

          # A declaration is gathered before the program is written, so it writes nothing where
          # it is; any other kind with no writer is a mistake in this file.
          def lower_declaration_or_refuse(node)
            return lower_nothing(node) if STATEMENT_KINDS.include?(node.kind)

            raise LoweringError, "the native backend has no row for #{node.kind.inspect}"
          end

          # A variable set to itself changes nothing, and C's compiler refuses the statement
          # written out, so nothing is written for one. A game comes to it honestly: a helper
          # that takes where to keep its answer, handed the place the answer already is.
          def lower_set(node)
            return [] if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            [assign(node.var, value(node.value))]
          end

          def lower_add(node) = [assign(node.var, call("rg_add", variable(node.var), value(node.operand)))]
          def lower_sub(node) = [assign(node.var, call("rg_sub", variable(node.var), value(node.operand)))]
          def lower_copy(node) = node.dest == node.src ? [] : [assign(node.dest, variable(node.src))]
          def lower_negate(node) = [assign(node.var, call("rg_neg", variable(node.var)))]
          def lower_abs(node) = [assign(node.var, call("rg_abs", variable(node.var)))]

          # -|v|: turned round only when it is above nought, so the lowest number stays itself.
          def lower_negate_abs(node)
            v = variable(node.var)
            [C::If.new(condition: call("rg_gt", v, C::Int.new(0)), body: [assign(node.var, call("rg_neg", v))])]
          end

          def lower_clamp(node)
            [assign(node.var, call("rg_clamp", variable(node.var), value(node.min), value(node.max)))]
          end

          def lower_if(node)
            otherwise = node.else ? body_of(node.else) : []
            [C::If.new(condition: value(node.cond), body: body_of(node), otherwise: otherwise)]
          end

          # Reference#exec_loop: the loop's statements in the order its console runs them
          # (IR::Frames.loop_in_console_order). On a console that places a frame's sprites and
          # scroll before its wait, each pass ends by placing them, and the first wait comes once
          # before the loop.
          def lower_loop(node)
            order = console_loop(node)
            running = loops_ending_passes.any? ? [C::Assign.new(running_loop_variable, C::Int.new((loops_ending_passes.index(node) || -1) + 1))] : []
            [*statements_of(order.before), *running,
             C::While.new(condition: C::Int.new(1), body: statements_of(order.each_time, order: order))]
          end

          def console_loop(node)
            (@console_loops ||= {})[node.object_id] ||= Frames.console_order_of(node, @program.described_console)
          end

          # The game loops that end each pass by placing the frame's writes
          # (IR::Frames::ConsoleLoop#pass_end), which a halt has to end as the running one does.
          def loops_ending_passes
            @loops_ending_passes ||= @program.walk.select { |node| node.kind == :loop && console_loop(node).pass_end.any? }
          end

          # Which of those is running, counted from 1, and nought for none: a halt can be anywhere,
          # in a routine called from any loop or from none (#lower_halt).
          def running_loop_variable = @names.own("loop_running")

          # The variables the game loops keep of their own in their console's order.
          def loop_variables = @program.walk.select { |node| node.kind == :loop }.flat_map { |node| console_loop(node).variables }

          # A counted loop. The count is read once, before the first pass, as the interpreter
          # reads it; the index counts 0, 1, 2... and is stored in the game's variable at the
          # top of each pass; and +stop_when+ is asked BEFORE the body, so a loop already
          # finished on its first pass runs the body no times.
          def lower_repeat(node)
            count = local_name("count")
            index = local_name("index")
            pass = []
            pass << assign(node.index, index) if node.index
            pass << C::If.new(condition: value(node.stop_when), body: [C::Break.new]) if node.stop_when
            pass.concat(body_of(node))
            pass << C::Assign.new(index, call("rg_add", index, C::Int.new(1)))
            [C::Block.new([C::Local.new(name: count, value: value(node.count)),
                           C::Local.new(name: index, value: C::Int.new(0)),
                           C::While.new(condition: call("rg_lt", index, count), body: pass)])]
          end

          # A beat (`every`, `after`) is the plain statements IR::Frames turns it into.
          def lower_beat(node) = Frames.beat_statements(node).flat_map { |statement| lower(statement) }

          alias lower_every lower_beat
          alias lower_after lower_beat

          def lower_call(node) = [C::Eval.new(C::Call.new(function: routine(node.target)))]

          def eval_call(function, *args) = C::Eval.new(call(function, *args))

          # One of a list of routines by a number the game works out. The number is checked
          # against the ends of the list before the array is read, so a number naming no
          # routine calls nothing.
          def lower_call_one_of(node)
            which = local_name("which")
            last = C::Int.new(node.targets.length - 1)
            in_range = call("rg_both", call("rg_ge", which, C::Int.new(0)), call("rg_le", which, last))
            picked = C::Index.new(routine_table_name(node.targets), which)
            [C::Block.new([C::Local.new(name: which, value: value(node.which)),
                           C::If.new(condition: in_range, body: [eval_call("rg_call_routine", picked)])])]
          end

          # Picks the scene to run by the variable, read ONCE: a scene usually ends by setting
          # the variable to the next scene, and reading it again per clause would run that one
          # too, in the same pass.
          def lower_case(node)
            state = local_name("state")
            clauses = node.clauses.map do |clause_value, target|
              C::If.new(condition: call("rg_eq", state, C::Int.new(clause_value)), body: scene_call_statements(target))
            end
            [C::Block.new([C::Local.new(name: state, value: variable(node.var)), *clauses])]
          end

          # The statements that run +scene+ for a pass. A scene taking over is remembered, so what
          # a scene does as it arrives — its screen, its scenery — happens on the frame it changes
          # and not again while it stays. A scene that loads first and is handed over to has that
          # pass to itself for its pictures, and its routine runs from the pass after; the scene up
          # at power-on, which nothing handed over to, runs on the first pass all the same (see
          # IR::SceneHandover::Arrival#loads_first?). Before any scene, the note holds -1.
          def scene_call_statements(scene)
            current = @names.own("scene")
            number = C::Int.new(@scenes.fetch(scene))
            work = [C::Eval.new(C::Call.new(function: routine(scene)))]
            arriving = [C::Assign.new(current, number), *scene_arrival(scene)]
            taking_over = call("rg_ne", current, number)
            return [C::If.new(condition: taking_over, body: arriving), *work] unless @handover.arrival(scene).loads_first?

            at_power_on = local_name("at_power_on")
            [C::If.new(condition: taking_over,
                       body: [C::Local.new(name: at_power_on, value: call("rg_eq", current, C::Int.new(-1))),
                              *arriving, C::If.new(condition: at_power_on, body: work)],
                       otherwise: work)]
          end

          # A pass that halts ends as every pass does, with its sprites and scroll placed: the
          # running game loop's (Reference#place_pass_end_before_halt), and nothing before any runs.
          def lower_halt(_node)
            ends = loops_ending_passes.each_with_index.map do |ending, i|
              order = console_loop(ending)
              C::If.new(condition: call("rg_eq", running_loop_variable, C::Int.new(i + 1)),
                        body: statements_of(order.pass_end, order: order))
            end
            [*ends, eval_call("rg_halt")]
          end

          # Reference#exec_rumble. A desktop or a web page shakes no gamepad yet, but the runtime
          # keeps the motor as the console runs it, on a console whose cartridge carries one.
          def lower_rumble(node) = [eval_call("rg_rumble", value(node.frames), value(node.pattern))]

          # --- timers (Reference#exec_timer_start, #exec_timer_stop, #timer_ticks) ---

          # The most timers a game may have (RG_MAX_TIMERS).
          MAX_TIMERS = 32

          # Every timer the program names, by starting it, stopping it, reading it or saying what
          # it does when it ticks, and the number the runtime knows each by.
          def timer_numbers
            names = @program.walk.filter_map do |node|
              case node.kind
              when :timer_start, :timer_stop, :timer_ticks then node.name
              when :on_timer then node.timer
              end
            end.uniq
            if names.size > MAX_TIMERS
              raise LoweringError, "this program has #{names.size} timers, and #{build_name} has room for #{MAX_TIMERS}."
            end

            names.each_with_index.to_h
          end

          def timer_number(name) = C::Int.new(@timers.fetch(name))

          # The interpreter's sixty frames a second go with the rate, so the C divides by the
          # number Ruby divides by.
          def lower_timer_start(node)
            [eval_call("rg_timer_start", timer_number(node.name), C::Int.new(node.hz), C::Int.new(Reference::FRAME_RATE))]
          end

          def lower_timer_stop(node) = [eval_call("rg_timer_stop", timer_number(node.name))]
          def value_of_timer_ticks(node) = call("rg_timer_ticks", timer_number(node.name))

          # The routine the runtime calls for each tick of a timer (Reference#accrue_timer),
          # running what that timer does when it ticks. Where a handler is written, nothing
          # runs: it is its timer's, not the line's (Reference#exec_on_timer).
          def timer_ticks
            handlers = @tick_handlers.map do |timer, handler|
              C::If.new(condition: call("rg_timer_ticking", timer_number(timer)), body: body_of(handler))
            end
            C::Function.new(name: @names.own("timer_ticks"), body: handlers, exported: true)
          end

          # A game whose light takes turns sets first whether the scene that just ran has it on
          # (Reference#advance_frame). The runtime ends the frame (shows it, reads the buttons, keeps time), and the frame
          # counters the program can read move on, where the interpreter moves them. Last, a game
          # that bends a background it has works every bend's lines out for the pass to come
          # (Reference#work_out_bends), and a game with a light works out where it falls
          # (Reference#work_out_shade).
          #
          # A console that places a pass's scroll before its wait works the bends out there too,
          # first of all, so a row's bend and its scroll show on one frame.
          def lower_wait_vblank(_node)
            count = variable(Frames::COUNT)
            bends = @bends.empty? ? [] : [eval_call("rg_screen_work_out_bends")]
            bends_first = @program.described_console.sprites_placed_before_wait
            [*(bends_first ? bends : []),
             *(@switches_shade ? [eval_call("rg_shade_switch", variable(IR::LightScenes::ON))] : []),
             eval_call("rg_wait_vblank"),
             assign(Frames::COUNT, call("rg_add", count, C::Int.new(1))),
             assign(Frames::SEEN, count),
             assign(Frames::STEP, C::Int.new(1)),
             *(bends_first ? [] : bends),
             *lower_show_light_now(nil)]
          end

          # The light worked out again where this is reached, so the picture shown at the next
          # frame's end is read with it (Reference#exec_show_light_now) — as every gap does too.
          def lower_show_light_now(_node) = @shade ? [eval_call("rg_screen_work_out_shade")] : []

          # --- lists (runtime/rg_list.h does the work and the checking) ---

          def lower_list_new(node)
            [node.full_of ? list_call("rg_list_full", node, C::Int.new(node.full_of)) : list_call("rg_list_empty", node)]
          end
          def lower_list_push(node) = [list_call("rg_list_push", node, value(node.value))]
          def lower_list_drop(node) = [list_call("rg_list_drop", node, C::Int.new(node.from == :front ? 1 : 0))]
          def lower_list_set(node) = [list_call("rg_list_set", node, value(node.index), value(node.value))]

          def lower_list_fill(node)
            [list_call("rg_list_fill", node, value(node.from), value(node.count), value(node.value))]
          end

          def lower_list_copy(node)
            table = @tables.fetch(node.table)
            kept = TABLE_KEPT_AS.fetch(table_type(table))
            [list_call("rg_list_copy", node, @names.of(:table, node.table), C::Int.new(kept), C::Int.new(table.entry_count),
                       value(node.at), C::Int.new(node.count))]
          end

          # Reference#exec_list_sort, as one call: the runtime sorts the list in place by the
          # numbers +by+ holds, stably.
          def lower_list_sort(node)
            [list_call("rg_list_sort", node, C::AddressOf.new(list(node.by)), C::Int.new(node.descending ? 1 : 0))]
          end

          def list_call(function, node, *args)
            C::Eval.new(call(function, C::AddressOf.new(list(node.name)), *args))
          end

          # --- values ---

          def value(operand)
            case operand
            when Integer then C::Int.new(Int32.wrap(operand))
            when Symbol then variable(operand)
            when Node then value_by_kind(operand)
            else raise LoweringError, "cannot write #{operand.inspect} as a number"
            end
          end

          def value_of_int(node) = C::Int.new(Int32.wrap(node.value))
          def value_of_var_ref(node) = variable(node.name)
          def value_of_binop(node) = call(OPERATORS.fetch(node.op), value(node.lhs), value(node.rhs))
          def value_of_neg(node) = call("rg_neg", value(node.operand))
          def value_of_bit_not(node) = call("rg_not", value(node.operand))
          def value_of_absolute(node) = call("rg_abs", value(node.operand))
          def value_of_clamped(node) = call("rg_clamp", value(node.operand), value(node.min), value(node.max))
          def value_of_mul_fix(node) = call("rg_mul_fix", value(node.lhs), value(node.rhs), fraction_bits(node))
          def value_of_div_fix(node) = call("rg_div_fix", value(node.lhs), value(node.rhs), fraction_bits(node))

          # How many bits of a number hold its fraction. rg_int32.h is written for 0 to 32,
          # which is every scale the framework uses; any other would shift past what its 64-bit
          # sums can hold.
          def fraction_bits(node)
            bits = node.fraction_bits
            raise LoweringError, "a fraction kept in #{bits} bits cannot be written as C (0 to 32 can)" unless bits.between?(0, 32)

            C::Int.new(bits)
          end
          def value_of_shift_right(node) = call("rg_shr", value(node.operand), C::Int.new(node.bits))

          # A READING OF THE CARTRIDGE'S CLOCK, asked of the runtime by its place in
          # IR::Clock::READINGS. Where the time comes from is the runtime's driver's to set: the
          # computer's clock in a window, the test's moment with none (rg_driver.h).
          #
          # A time the game set is added on, from the two saved numbers it is kept in, in a game
          # that sets one (see IR::Clock::OFFSET_DAYS).
          def value_of_clock(node)
            offsets = sets_clock? ? IR::Clock::OFFSETS.map { |name| variable(name) } : [C::Int.new(0), C::Int.new(0)]
            call("rg_clock_reading", C::Int.new(IR::Clock::READINGS.index(node.reading)), *offsets)
          end

          def sets_clock? = @sets_clock.nil? ? (@sets_clock = IR::Clock.sets_clock?(@program)) : @sets_clock

          # SETTING THE CLOCK: the runtime works out how far the time set is from its clock's, and
          # the game keeps the two parts in its saved numbers (Reference#exec_set_clock).
          def lower_set_clock(node)
            parts = [node.year, node.month, node.day, node.hour, node.minute, node.second].map { |part| value(part) }
            [eval_call("rg_clock_set_to", *parts),
             assign(IR::Clock::OFFSET_DAYS, call("rg_clock_kept_days", variable(IR::Clock::OFFSET_DAYS))),
             assign(IR::Clock::OFFSET_SECONDS, call("rg_clock_kept_seconds", variable(IR::Clock::OFFSET_SECONDS)))]
          end

          def value_of_held(node) = button_call("rg_held", node)
          def value_of_pressed(node) = button_call("rg_pressed", node)

          # The first player's button is a bit to look at. Anything that names another player asks
          # the runtime about that player's buttons, by number (0 for any connected player), and a
          # mask of the buttons it asks about in one player's bits (IR::Buttons.player_mask).
          def button_call(reader, node)
            return call(reader, C::Int.new(button_number(node.button))) if node.player == 1

            player = node.player == Buttons::ANY ? 0 : node.player
            mask = Buttons.player_mask(Buttons.names_asked(node.button, 1), 1)
            call("#{reader}_by", C::Int.new(player), C::Int.new(mask))
          end

          # How many players are connected now (IR::Buttons.masks): the length of the list of
          # buttons the driver hands the runtime each pass.
          def value_of_players_connected(_node) = call("rg_players_connected")
          def value_of_local_player(_node) = call("rg_local_player")

          # A chance holds when the random draw lands below the threshold.
          def value_of_chance(node) = call("rg_lt", value(node.draw), C::Int.new(node.percent))

          # A table read with an index out of range made safe the way the other backends make
          # it: a table whose length is a power of two wraps the index (what an angle wants),
          # any other clamps it to the ends.
          def value_of_table_get(node)
            count = @tables.fetch(node.name).entry_count
            index = value(node.index)
            safe = if count.positive? && (count & (count - 1)).zero?
                     call("rg_and", index, C::Int.new(count - 1))
                   else
                     call("rg_clamp", index, C::Int.new(0), C::Int.new(count - 1))
                   end
            C::Index.new(@names.of(:table, node.name), safe)
          end

          def value_of_list_get(node) = call("rg_list_get", C::AddressOf.new(list(node.name)), value(node.index))
          def value_of_list_len(node) = call("rg_list_length", C::AddressOf.new(list(node.name)))

          # One byte of a named piece of data. The index is a number written in the program, so
          # one past the end is refused here, where the interpreter would refuse it as it runs.
          def value_of_data_byte(node)
            data = @data.fetch(node.name) { raise LoweringError, "reference to undefined data #{node.name.inspect}" }
            length = (data.kind == :data ? data.bytes : data.pixels).bytesize
            unless node.index.between?(0, length - 1)
              raise LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}"
            end

            C::Index.new(@names.of(:data, node.name), C::Int.new(node.index))
          end

          # --- names and small pieces ---

          # The buttons in the order the console's key register holds them, which is also
          # IR::Buttons::NAMES's order; -1 means any of them.
          def button_number(button)
            return -1 if button == Buttons::ANY

            Buttons::NAMES.index(button) or raise LoweringError, "unknown button #{button.inspect}"
          end

          # Every scene a `case` can hand over to, numbered from 0 in the order they appear.
          def scene_numbers
            @program.walk.select { |node| node.kind == :case }.flat_map { |node| node.clauses.map(&:last) }
                    .uniq.each_with_index.to_h
          end

          def variable(name) = @names.of(:variable, name)
          def list(name) = @names.of(:list, name)
          def routine(name) = @names.of(:routine, name)
          def routine_table_name(targets) = @names.of(:table_of_routines, targets.join("_"))
          def assign(name, expression) = C::Assign.new(variable(name), expression)
          def call(function, *args) = C::Call.new(function: C::Name.new(function), args: args)

          def local_name(what)
            @locals += 1
            @names.of(:local, "#{what}#{@locals}")
          end
        end
      end
    end
  end
end
