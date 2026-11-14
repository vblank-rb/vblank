# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class DOS
        # THE IR LOWERED FOR A PC: a walk of the program that writes 386 instructions through the assembler
        # (X86), with the runtime (Runtime) linked behind it. It is a peer of the other cartridge lowerings,
        # and shares what they decide before writing an instruction (LoweringPlan, BuildCache).
        #
        # WHERE THINGS ARE. Every number of the game is a 32-bit word in the data segment, reached by DS and an
        # offset (Memory). The game's own code is the routine MAIN, which the runtime calls. A value is worked
        # out into EAX; a binary operation works its left into EAX, its right into ECX and does one
        # instruction on the pair, or calls a runtime routine (Runtime) where IR::Int32 differs from the
        # processor: divide, remainder, and a shift of 32 or more. Everything but addition, subtraction,
        # multiplication and the bit operations is therefore a call, and nothing here ever uses an
        # instruction on a game's number whose answer Int32 gives otherwise.
        #
        # WHAT IT MAKES SO FAR: a game's numbers, its loops (the game loop in the console's order, repeat),
        # its conditions and halting, the keyboard's keys as buttons, save memory kept in a file, the clock, and a
        # painted screen of one page with a cleared screen, pixels, an area drawing is held to,
        # rectangles, pictures (`blit`), text and numbers, in a palette of the colours the game names.
        # Everything else is refused by name until it is made (NOT_LOWERED_YET), and what a PC cannot do at
        # all is refused in the words its answers have (Console::Answers#refusals).
        class Lowering
          include ControlFlow
          include TimerSteps
          include Clock
          include Sprites
          include Lists
          include Scenery

          # A program refused because it reaches something the build does not make yet, with the +part+ of
          # the build that is missing, for a test run to count skips by.
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          # EVERY KIND THIS LOWERING WRITES, each by a method called by name in #emit_statement and
          # #emit_value_of_kind. A declaration writes nothing where it is.
          STATEMENT_KINDS = (%i[
            program set add sub copy negate abs negate_abs clamp call call_one_of halt wait_vblank screen clear_screen pixel fill_rect dma_fill_rect
            draw_rect_at blit blit_pose inside draw_text draw_digit save_region restore_region fade tint camera pixelate draw_column_at save_init save_store save_write save_erase
            save_load_list save_store_list
          ] + ControlFlow::STATEMENT_KINDS + TimerSteps::STATEMENT_KINDS + Clock::STATEMENT_KINDS + Sprites::STATEMENT_KINDS + Lists::STATEMENT_KINDS + Scenery::STATEMENT_KINDS +
            Nodes.of_role(:declaration)).freeze

          VALUE_KINDS = (%i[int var_ref binop neg clamped absolute bit_not shift_right mul_fix div_fix chance data_byte table_get
                            held pressed save_read save_sum local_player players_connected pixels_overlap] + TimerSteps::VALUE_KINDS + Clock::VALUE_KINDS + Lists::VALUE_KINDS).freeze

          # The statements that paint in a colour the game names, which the palette must hold.
          PAINTING_KINDS = %i[clear_screen pixel fill_rect dma_fill_rect draw_rect_at draw_text draw_digit].freeze

          # EVERY KIND THIS LOWERING CANNOT MAKE YET: all the others. A kind leaves the list the day it is made
          # (the coverage test holds the list and the two above to every kind there is).
          NOT_LOWERED_YET = Ractor.make_shareable({
            Console::DOSAnswers::NOT_MADE_YET_PART =>
              (Nodes.of_role(:statement) + Nodes.of_role(:value) + Nodes.of_role(:declaration))
                .reject { |kind| Portability.hardware_only?(kind) }
                .reject { |kind| STATEMENT_KINDS.include?(kind) || VALUE_KINDS.include?(kind) }.sort
          })

          # The label of the routine the program itself is, which the runtime calls at power-on.
          MAIN = "main"

          # The console this lowers for (BuildCache).
          CONSOLE = Console::DOS

          # The binops that compare two numbers (emit_comparison).
          COMPARISONS = %i[< <= > >= == !=].freeze

          # What the build works out once for every try (BuildCache#facts), which BuildCache asks every
          # lowering for. The DOS build makes one try, since its code is one segment with no banks to fit, so
          # there is nothing of its own to keep.
          class BuildFacts
            def initialize(_cache); end
          end

          # Where each variable went (its offset in the data segment), by its name, the palette the screen is
          # drawn in (15-bit colours, entry 0 black), and what starts as something other than nought.
          attr_reader :variables, :palette, :starts

          # The pictures the game draws, as the bytes of the art segment (each picture's width and height, then a
          # palette entry a pixel), and whether there are any.
          attr_reader :art

          # The label of the routine the runtime runs at each frame boundary (TimerSteps), or nil for a game
          # with no timers.
          attr_reader :frame_begins, :bends_routine

          def pictures? = !@art_places.empty?

          # Whether the game keeps and puts back patches of its picture, and so carries the runtime's routines
          # for that (Runtime::Regions).
          def regions? = @program.walk.any? { |node| %i[save_region restore_region].include?(node.kind) }

          # Whether +program+ fades or tints, and so carries the runtime's walk of the palette (Runtime::Fades).
          def self.walks_colors?(program) = program.walk.any? { |node| %i[fade tint].include?(node.kind) }

          # Whether +program+ moves the view over its picture or shows it in blocks, and so is shown a picture made from its own
          # (Runtime::View).
          def self.shown_through_view?(program) = program.walk.any? { |node| %i[camera pixelate].include?(node.kind) }

          # Whether +program+ draws stretched columns of a picture, and so carries the runtime's routine for one.
          def self.draws_columns?(program) = program.walk.any? { |node| node.kind == :draw_column_at }

          # Whether +program+ divides a number that holds a fraction, and so carries the runtime's routine for it.
          def self.divides_fractions?(program) = program.walk.any? { |node| node.kind == :div_fix }

          # Whether +program+ holds any drawing to an area, and so keeps one (Runtime::AREA).
          def self.area_used_by?(program) = program.walk.any? { |node| node.kind == :inside }

          def area? = Lowering.area_used_by?(@program)

          # Whether the game keeps anything in save memory, and so carries the runtime's saving (Runtime::Saving).
          def saves? = SaveLayout.named_by?(@program)

          def initialize(program, memory:, cache: BuildCache.for(DOS, program))
            @program = program
            @memory = memory
            @cache = cache
            @plan = cache.plan
            @variables = {}
            @locals = {}
            @locals_of_routine = {} # a routine's label -> the names of the numbers it keeps
            @starts = []
            @labels = 0
            @routine = MAIN
            @art = "".b
            @art_places = {}
          end

          # Writes the game's code, as the routine MAIN, into +asm+ (an X86).
          def emit(asm)
            @asm = asm
            refuse_what_cannot_be_made!
            reserve_variables
            @palette = palette_of(@program)
            make_art
            DOS.refuse_too_much_art!(@art.bytesize)
            @scene = keep_local(:scene, start: -1) unless @plan.scenes.empty?
            reserve_lists
            keep_timer_numbers
            keep_loop_running
            keep_clock_readings
            keep_patches
            @asm.label(MAIN)
            emit_clock_at_start
            @program.children.each { |node| emit_statement(node) }
            @asm.ret
            emit_routines
            @frame_begins = emit_timer_routines
            @bends_routine = emit_bend_routine
            Runtime::Sprites.emit_paint_tile(@asm) if @program.walk.any? { |node| node.kind == :load_sprite_tiles }
            emit_live_bend_routine
            emit_clock_routines
          end

          private

          def refuse_what_cannot_be_made!
            Backends.refuse_start_file_on_cartridge!(@program, @plan.console, LoweringError)
            @plan.refuse_hardware_only_kinds!
            refuse_unmade_save_memory! # before the kinds: a chip's layout brings steps a file never needs
            @plan.refuse_kinds_not_made_yet!(NOT_LOWERED_YET, NotMadeYet)
            @plan.refuse_routines_that_call_themselves!
            @plan.refuse_what_console_lacks!
            refuse_unmade_variant!
            refuse_unmade_screens!
            refuse_unmade_sprites!
            refuse_unmade_fades!
          end

          # A DOS game saves in a file of 32K, written a byte at any time (Runtime::Saving). A game that names
          # flash or an EEPROM lays its save memory out for that chip, its blocks wiped before they are
          # written, which a file has no need of.
          def refuse_unmade_save_memory!
            return unless saves?

            memory = SaveLayout.memory_of(@program)
            return if memory.battery?

            asked = @program.walk.find { |node| node.kind == :save_memory }&.asked_for
            fix = asked ? "leave `save_memory:` out of the game" : "keep less in the game's `save_data` records"
            raise LoweringError, "This game saves in #{memory.kilobytes}K of #{memory.kind_words}, and a #{CONSOLE.title} " \
                                 "game saves in a file of 32K. To fix this, #{fix}."
          end

          # The part of the build a game with a screen variant waits for, for a test run to count skips by.
          VARIANT_PART = "the 640 × 480 screen (variants: { dos: :vesa_640x480 })"

          # The screens the runtime sets and sends a picture to (Runtime::ModeX is the 320 × 240 one's).
          MODES_MADE = %i[mode_13h mode_x].freeze

          # A variant whose screen is not made yet (Console::DOSKit::DOS_VARIANTS): the program would set
          # another mode and draw its rows while the game is told it has the variant's. So a game that names
          # one is refused.
          def refuse_unmade_variant!
            return if MODES_MADE.include?(@memory.screen.mode)

            variant = Console.for(:dos).variant(@program.variant)
            raise NotMadeYet.new("This game is for #{CONSOLE.title} with #{variant.title}. The #{CONSOLE.title} build " \
                                 "cannot make that screen yet. To fix this, remove dos: from variants: or from " \
                                 "--variant, or use `variants: { dos: :mode_x }`, the 320 × 240 screen.",
                                 part: VARIANT_PART)
          end

          # A screen drawn from tiles is made as far as Scenery says. A tear-free screen (`tear_free: true`) is the
          # painted screen as it always is here: one picture in memory, sent to the card in the retrace
          # (Console::Description, painted_pages).
          def refuse_unmade_screens! = refuse_unmade_scenery!

          def loop_variables = @plan.game_loops.flat_map { |node| console_loop(node).variables }

          def reserve_variables
            (Reach.variables(@program) | loop_variables).each do |name|
              @variables[name] = @memory.reserve(name, 4, what: "the variable #{name.inspect}")
            end
          end

          # The colours the game names, as the 15-bit numbers the interpreter paints with, after black.
          def palette_of(program)
            colors = program.walk.select { |node| PAINTING_KINDS.include?(node.kind) }
                            .flat_map { |node| [node.color, (node.picked if node.kind == :draw_text)].compact }
                            .map { |color| Graphics::Color.resolve(color) }.uniq - [0]
            colors |= drawn_pictures.flat_map { |name| picture_colors(name) } - [0]
            colors |= recolored_sprite_colors - [0]
            colors |= scenery_colors - [0]
            colors |= sprite_tile_colors - [0]
            if colors.size >= TRANSPARENT_ENTRY
              raise LoweringError, "This game paints with #{colors.size} colours besides black. DOS shows " \
                                   "#{TRANSPARENT_ENTRY - 1} at once, and every list a sprite is drawn with adds its colours. " \
                                   "To fix this, use fewer colours."
            end
            [0, *colors]
          end

          # The palette entry that means "nothing here" in a picture, so no colour is given it.
          TRANSPARENT_ENTRY = Runtime::TRANSPARENT

          # Every picture a `blit` draws, and every one a `blit` of several picks from.
          def drawn_pictures
            @program.walk.flat_map do |node|
              case node.kind
              when :blit, :draw_column_at then [node.name]
              when :blit_pose then node.poses
              when :pixels_overlap then node.a_poses + node.b_poses
              else []
              end
            end.concat(sprite_pictures).uniq
          end

          def picture_node(name)
            @pictures_declared ||= @program.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node] }
            @pictures_declared.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
          end

          def make_text_pictures
            @program.walk.select { |node| node.kind == :draw_text }.each do |node|
              [node.color, node.picked].compact.each do |color|
                key = text_key(node, color)
                @art_places[key] = picture_of_text(node.fonts.get(node.font), node.text, color) unless @art_places.key?(key)
              end
            end
          end

          # Each digit a game draws as it runs: ten pictures, 0 to 9, in the font and colour, and a table of their
          # places (a word each) that the digit's value picks from. A digit the font has no pixels for is a
          # picture of no rows.
          def make_digit_pictures
            @program.walk.select { |node| node.kind == :draw_digit }.each do |node|
              key = digits_key(node)
              next if @art_places.key?(key)

              places = (0..9).map { |digit| picture_of_text(node.fonts.get(node.font), digit.to_s, node.color) }
              @art_places[key] = @art.bytesize
              @art << places.pack("v10")
            end
          end

          def digits_key(node) = [:digits, node.font, Graphics::Color.resolve(node.color)]

          # The place in the art segment of the picture of +text+ in +color+, made now: its width and height,
          # then its pixels as palette entries, or no rows at all where the font draws nothing of it.
          def picture_of_text(font, text, color)
            drawn = []
            font.each_pixel(text) { |x, y| drawn << [x, y] }
            place = @art.bytesize
            return place.tap { @art << [0, 0].pack("v2") } if drawn.empty?

            width = drawn.map(&:first).max + 1
            height = drawn.map(&:last).max + 1
            pixels = Array.new(width * height, Runtime::TRANSPARENT)
            drawn.each { |x, y| pixels[(y * width) + x] = palette_entry(color) }
            @art << [width, height].pack("v2") << pixels.pack("C*")
            place
          end

          def text_key(node, color = node.color) = [:text, node.text, node.font, Graphics::Color.resolve(color)]

          def picture_image(name) = (@images ||= {})[name] ||= tile_pose_image(name) || @cache.image(picture_node(name))

          # The 15-bit colours a picture draws, not counting what it leaves transparent.
          def picture_colors(name)
            image = picture_image(name)
            (0...(image.width * image.height)).select { |at| image.drawn_at?(at) }.map { |at| image.color_at(at) }.uniq
          end

          # Each picture the game draws, and each text it writes, made into its bytes of the art segment once its
          # palette is known. A text is the picture of its pixels in its font and colour, which is how the
          # interpreter draws it (Reference#exec_draw_text), and the same text in the same colour is one picture.
          def make_art
            make_text_pictures
            make_digit_pictures
            drawn_pictures.each do |name|
              image = picture_image(name)
              @art_places[name] = @art.bytesize
              @art << [image.width, image.height].pack("v2")
              @art << (0...(image.width * image.height)).map do |at|
                image.drawn_at?(at) ? palette_entry(image.color_at(at)) : Runtime::TRANSPARENT
              end.pack("C*")
            end
            make_pose_tables
            make_sprite_tables
            make_tables
            make_sprite_tile_art
            make_scenery_art
          end

          # For each `blit` of several pictures, a table of their places (a word each) that the number picks from.
          # The same for each side of a `pixels_overlap`.
          def make_pose_tables
            pose_lists = @program.walk.flat_map do |node|
              case node.kind
              when :blit_pose then [node.poses]
              when :pixels_overlap then [node.a_poses, node.b_poses]
              else []
              end
            end
            pose_lists.uniq.each do |poses|
              @art_places[poses_key(poses)] = @art.bytesize
              @art << poses.map { |name| @art_places.fetch(name) }.pack("v*")
            end
          end

          def palette_entry(color) = @palette.index(Graphics::Color.resolve(color))

          # @routine is MAIN until routines (`func`, scenes) are made: the labels and the numbers of each are
          # named for the routine they are in, so two routines' never meet.
          def fresh_label(what)
            @labels += 1
            "#{@routine}.#{what}##{@labels}"
          end

          # A number of the routine's own, kept in the data segment, by a name a value can read as a variable.
          def keep_local(what, start: 0)
            name = DerivedNames.local_number_name(@routine, what, @locals.length + 1)
            (@locals_of_routine[@routine] ||= []) << name
            @locals[name] = @memory.reserve(name, 4, what: "the game's number #{name}")
            @starts << [@locals[name], start] unless start.zero?
            name
          end

          def place_of(name)
            @variables.fetch(name) { @locals.fetch(name) { raise LoweringError, "#{name.inspect} is not a variable the program keeps" } }
          end

          def number_at(name) = X86.mem(nil, place_of(name), size: 32)
          def runtime_at(name) = X86.mem(nil, @memory[name], size: 32)

          def console_loop(node) = @plan.console_loop(node)
          def loop_form = @plan.loop_form
          def folded(node) = @plan.folded(node)

          # --- statements ---

          # An owed view of a screen of tiles is built first where the interpreter builds it (Scenery).
          def emit_statement(node)
            emit_owed_scenery_paint(node)
            emit_picture_drawn_over(node)
            with_pass_end_placing(node) { emit_statement_of_kind(node) }
          end

          def emit_statement_of_kind(node)
            case node.kind
            when :program then node.children.each { |child| emit_statement(child) }
            when :set then emit_set(node)
            when :add then emit_sum(node.var, :+, node.operand)
            when :sub then emit_sum(node.var, :-, node.operand)
            when :copy then emit_copy(node)
            when :negate then @asm.neg(number_at(node.var))
            when :abs then emit_sign_held(node.var, above_nought: true)
            when :negate_abs then emit_sign_held(node.var, above_nought: false)
            when :clamp then emit_clamp(node)
            when *ControlFlow::STATEMENT_KINDS then emit_control_flow_statement(node)
            when *TimerSteps::STATEMENT_KINDS then emit_timer_statement(node)
            when *Lists::STATEMENT_KINDS then emit_list_statement(node)
            when :call then emit_call(node)
            when :call_one_of then emit_call_one_of(node)
            when :halt then emit_halt
            when :wait_vblank then emit_wait_vblank
            # Mode 13h is set at power-on, and a screen of one page is all there is; a screen of tiles shows its backdrop.
            when :screen then emit_screen(node) if scenery_used?
            when :background then emit_background(node)
            when :scroll_background then emit_scroll_background(node)
            when :place_bar then emit_place_bar(node)
            when :hide_sprites then emit_hide_sprites
            when :load_sprite_tiles then emit_load_sprite_tiles(node)
            when :show_picture_group then nil # every picture is in reach whatever group is up (Lowering::Sprites)
            when :scroll_rows then emit_scroll_rows
            when :affine_background then emit_affine_background(node)
            when :box_background then emit_box_background(node)
            when :set_tile then emit_set_tile(node)
            when :show_held_tiles then emit_show_held_tiles(node)
            when :show_map then emit_show_map(node)
            when :copy_tiles then emit_copy_tiles(node)
            when :copy_owed_tiles then emit_copy_owed_tiles(node)
            when :background_colors then emit_background_colors(node)
            when :clear_screen then emit_clear_screen(node)
            when :pixel then emit_pixel(node)
            when :camera then emit_camera(node)
            when :draw_column_at then emit_draw_column_at(node)
            when :color_list_holds then emit_color_list_holds(node)
            when :pixelate then emit_pixelate(node)
            when :fill_rect, :dma_fill_rect, :draw_rect_at then emit_rectangle(node)
            when :blit then emit_blit(node)
            when :blit_pose then emit_blit_pose(node)
            when :inside then emit_inside(node)
            when :fade, :tint then emit_walk(node)
            when :save_region then emit_save_region(node)
            when :restore_region then emit_restore_region(node)
            when :draw_text then emit_draw_text(node)
            when :draw_digit then emit_draw_digit(node)
            when :save_init then emit_save_init(node)
            when :set_clock then emit_set_clock(node)
            when :present_objects then emit_present_objects(node)
            when :save_store then emit_save_write_word(SaveLayout.save_var_at(node.slot), Build.var_ref(node.var))
            when :save_write then emit_runtime_call("rt_save_write", node.at, node.value, save_width(node))
            # A file takes any byte at any time, so nothing is wiped; the place is worked out all the same,
            # as the interpreter works it out (Reference#exec_save_erase).
            when :save_erase then emit_value(node.at)
            # Reference#exec_save_load_list and #exec_save_store_list, as the loops the steps stand for.
            when :save_load_list, :save_store_list then SaveListMoves.loops_for(node).each { |loop| emit_statement(loop) }
            else emit_declaration_or_refuse(node)
            end
          end

          # A declaration is gathered before the program is written, so it writes nothing where it is; any
          # other kind with no writer is a mistake in this file.
          def emit_declaration_or_refuse(node)
            return if Nodes.of_role(:declaration).include?(node.kind)

            raise LoweringError, "no writer here for #{node.kind.inspect}"
          end

          def emit_set(node)
            return if node.value.is_a?(Node) && node.value.kind == :var_ref && node.value.name == node.var

            known = folded(node.value)
            return emit_number_into(node.var, known) if known # one instruction, where a load and a store are two

            emit_value(node.value)
            emit_store(node.var)
          end

          def emit_copy(node)
            return if node.dest == node.src

            emit_value(node.src)
            emit_store(node.dest)
          end

          # `x = x + n` and `x = x - n`.
          def emit_sum(name, op, operand)
            emit_value(Build.binop(op, Build.var_ref(name), operand))
            emit_store(name)
          end

          def emit_store(name) = @asm.mov(number_at(name), :eax)

          # --- what ControlFlow asks of a lowering, in the 386's instructions ---

          def place_label(label) = @asm.label(label)
          def jump(label) = @asm.jmp(label)
          def jump_unless(condition, label) = emit_jump_unless(condition, label)
          def jump_if(condition, label) = (emit_jump_if(condition, label) unless condition.nil?)
          def statement(node) = emit_statement(node)
          def children_of(node) = [node.children, (node.else&.children if node.kind == :if) || []]
          def loop_statements(node) = console_loop(node).each_time
          def game_loops = @plan.game_loops
          def emit_store_zero(name) = emit_number_into(name, 0)
          def emit_increment(name) = emit_sum(name, :+, Build.int(1))

          def emit_copy_variable(from, to)
            @asm.mov(:eax, number_at(from))
            emit_store(to)
          end

          def emit_number_into(name, number)
            @asm.mov(number_at(name), Int32.wrap(number) & 0xFFFF_FFFF)
          end

          # --- routines and scenes ---

          # The label of the routine the game names +name+ (a `func`, or a scene).
          def self.routine_label(name) = "routine #{name}"

          # Each routine a run can reach, after the program itself: its statements and a return. Its labels
          # and the numbers of its own are named for it (#fresh_label, #keep_local), and those numbers are
          # kept in the data segment and not on the stack, which is why a routine cannot call itself
          # (LoweringPlan#refuse_routines_that_call_themselves!).
          def emit_routines
            @plan.called.each do |name|
              @routine = Lowering.routine_label(name)
              @lowering_scene = (name if Modes.scene_func?(name)) # whose backgrounds a name means (#for_background)
              @asm.label(@routine)
              @plan.funcs.fetch(name).children.each { |node| emit_statement(node) }
              @asm.ret
            end
            @routine = MAIN
            @lowering_scene = nil
          end

          # --- what TimerSteps asks of a lowering ---

          def emit_store_number(name, number) = emit_number_into(name, number)
          def call_routine(label) = @asm.call(label)

          # A handler's statements (TimerSteps), with every number its run could leave changed for whoever it
          # interrupted kept on the stack while it runs and put back after:
          #
          #   - the numbers of every routine it can call. The game may be waiting in the middle of one of them,
          #     part way through a loop whose count is in the data segment, and the handler's own call of it
          #     would leave the count where its loop ended;
          #   - the handler's own, and the count of ticks still to answer. A handler that waits a frame is
          #     in the middle of its own loops when the next frame's ticks run it again.
          #
          # The handler's own numbers are not known until its statements are written, so the keeping is
          # written after them and jumped to first.
          def with_interrupted_numbers_kept(handler, &) = with_numbers_kept([handler], [@timer_crossed], &)

          # The statements the block writes, run at a frame boundary from +roots+ (a timer's handler, a bend), with
          # the numbers of every routine they can call, the routine's own and +also+ kept on the stack round them
          # (#with_interrupted_numbers_kept says why).
          def with_numbers_kept(roots, also = [])
            keep = fresh_label("keep_numbers")
            run = fresh_label("run_handler")
            put_back = fresh_label("put_numbers_back")
            @asm.jmp(keep)
            @asm.label(run)
            yield
            @asm.jmp(put_back)
            @asm.label(keep)
            called = roots.flat_map { |root| routines_called_from(root) }.uniq
                          .flat_map { |name| @locals_of_routine.fetch(Lowering.routine_label(name), []) }
            kept = (called + @locals_of_routine.fetch(@routine, []) + also).uniq
            kept.each do |name|
              @asm.mov(:eax, number_at(name))
              @asm.push(:eax)
            end
            @asm.jmp(run)
            @asm.label(put_back)
            kept.reverse_each do |name|
              @asm.pop(:eax)
              @asm.mov(number_at(name), :eax)
            end
          end

          # Every routine +node+'s statements can reach, by name: the ones it calls, and the ones those call.
          def routines_called_from(node, found = [])
            node.walk.each do |inner|
              called = case inner.kind
                       when :call then [inner.target]
                       when :call_one_of then inner.targets
                       when :case then inner.callees
                       else []
                       end
              (called - found).each do |name|
                found << name
                routines_called_from(@plan.funcs.fetch(name), found)
              end
            end
            found
          end

          # A routine of the lowering's own, named for itself as a game's routine is.
          def emit_own_routine(label)
            outer = @routine
            @routine = label
            @asm.label(label)
            yield
            @asm.ret
            @routine = outer
          end

          def emit_call(node)
            raise LoweringError, "the routine #{node.target.inspect} is called and never declared" unless @plan.funcs.key?(node.target)

            @asm.call(Lowering.routine_label(node.target))
          end

          # Reference#exec_call_one_of: the number worked out once, and the routine at that place of the list
          # called; a number naming none, below nought or past the list's end, calls nothing. The lists are a
          # few routines long, so each is asked in turn.
          def emit_call_one_of(node)
            done = fresh_label("called_one")
            emit_value(node.which)
            node.targets.each_with_index do |target, which|
              other = fresh_label("calls_another")
              @asm.cmp(:eax, which)
              @asm.jne(other)
              @asm.call(Lowering.routine_label(target))
              @asm.jmp(done)
              @asm.label(other)
            end
            @asm.label(done)
          end

          # A scene taking over is remembered, so what a scene does as it arrives happens on the pass it
          # changes and not again while it stays. A scene that loads first and is handed over to has that
          # pass to itself, and its routine runs from the pass after; the scene up at power-on, which
          # nothing handed over to, runs on the first pass all the same
          # (IR::SceneHandover::Arrival#loads_first?). Before any scene, the note holds -1.
          def emit_scene(scene)
            number = @plan.scenes.fetch(scene)
            label = Lowering.routine_label(scene)
            staying = fresh_label("scene_staying")
            done = fresh_label("scene_done")
            jump_unless(Build.binop(:!=, Build.var_ref(@scene), Build.int(number)), staying)
            if @plan.handover.arrival(scene).loads_first?
              at_power_on = keep_local(:at_power_on)
              emit_value(Build.binop(:==, Build.var_ref(@scene), Build.int(-1)))
              emit_store(at_power_on)
              emit_number_into(@scene, number)
              emit_scene_arrival(scene)
              jump_unless(Build.var_ref(at_power_on), done)
              @asm.call(label)
              @asm.jmp(done)
            else
              emit_number_into(@scene, number)
              emit_scene_arrival(scene)
            end
            @asm.label(staying)
            @asm.call(label)
            @asm.label(done)
          end

          def emit_halt
            loops_ending_passes.each_with_index do |ending, i|
              other = fresh_label("not_this_loop")
              emit_jump_unless(Build.binop(:==, Build.var_ref(@loop_running), Build.int(i + 1)), other)
              console_loop(ending).pass_end.each { |child| emit_statement(child) }
              @asm.label(other)
            end
            @asm.jmp("rt_halt")
          end

          # The runtime ends the frame, and the frame counters the program can read move on where the
          # interpreter moves them (Reference#store_frame_counters): the frames shown by every frame the pass
          # took, and what the game catches up by, both as the runtime counted them.
          def emit_wait_vblank
            @asm.call("rt_wait_vblank")
            emit_clock_each_pass
            return unless @variables.key?(Frames::COUNT)

            @asm.mov(:eax, number_at(Frames::COUNT))
            @asm.add(:eax, runtime_at(Runtime::Frame::FRAMES_TAKEN))
            emit_store(Frames::COUNT)
            emit_store(Frames::SEEN)
            @asm.mov(:eax, runtime_at(Runtime::Frame::STEP_TAKEN))
            emit_store(Frames::STEP)
          end

          # --- save memory: each step a call into Runtime::Saving, the places IR::SaveLayout's ---

          # Reference#exec_save_init: every `save_var` takes its saved number when save memory carries the
          # game's marker, and the number it was declared with when it does not. Each is written back, and
          # the marker after them, in the interpreter's order.
          def emit_save_init(node)
            saved = keep_local(:saved)
            marker = Int32.wrap(node.magic)
            emit_value(Build.binop(:==, Build.save_read(Build.int(SaveLayout::SAVE_VAR_MARKER_AT), width: :word), Build.int(marker)))
            emit_store(saved)
            node.vars.each do |kept|
              at = SaveLayout.save_var_at(kept.slot)
              declared = fresh_label("declared_number")
              chosen = fresh_label("number_chosen")
              emit_jump_unless(Build.var_ref(saved), declared)
              emit_value(Build.save_read(Build.int(at), width: :word))
              @asm.jmp(chosen)
              @asm.label(declared)
              @asm.mov(:eax, Int32.wrap(kept.default))
              @asm.label(chosen)
              emit_store(kept.name)
              emit_save_write_word(at, Build.var_ref(kept.name))
            end
            emit_save_write_word(SaveLayout::SAVE_VAR_MARKER_AT, Build.int(marker))
            emit_clock_readings_from_save
          end

          def emit_save_write_word(at, value)
            emit_runtime_call("rt_save_write", Build.int(at), value, Build.int(Reference::SAVE_WIDTHS.fetch(:word)))
          end

          # How many bytes a read or a write moves, by the width it names: the interpreter's own table.
          def save_width(node) = Build.int(Reference::SAVE_WIDTHS.fetch(node.width))

          # A routine of the runtime's called with its numbers in EAX, ECX and EDX, in that order; what it
          # answers is in EAX.
          def emit_runtime_call(routine, *operands)
            emit_values_into(%i[eax ecx edx].first(operands.size), operands.map { |operand| value_node(operand) })
            @asm.call(routine)
          end

          # --- the screen ---

          # A colour as four pixels of its palette entry, which the whole-screen fill stores a word at a time.
          def emit_clear_screen(node)
            return emit_clear_area(node) if area?

            @asm.mov(:eax, palette_entry(node.color) * 0x0101_0101)
            @asm.call("rt_clear_screen")
          end

          # Where the game holds drawing to an area, a cleared screen is the area cleared
          # (Framebuffer#clear): a rectangle of the whole screen, which the area holds to itself.
          def emit_clear_area(node)
            emit_values_into(%i[eax ecx edx ebx], [0, 0, @memory.screen.width, @memory.screen.height].map { |edge| Build.int(edge) })
            @asm.mov(:si, palette_entry(node.color))
            @asm.call("rt_fill_rect")
          end

          # Reference#exec_inside: drawing held to the rectangle while the children run, and the area there
          # was before given back after, from the stack. The rectangle is numbers written in the game, so its
          # edges are worked out here, each held to the screen, with no width or height where it has none left.
          def emit_inside(node)
            left = node.x.clamp(0, @memory.screen.width)
            top = node.y.clamp(0, @memory.screen.height)
            edges = [left, top, (node.x + node.w).clamp(left, @memory.screen.width), (node.y + node.h).clamp(top, @memory.screen.height)]
            places = Array.new(4) { |i| X86.mem(nil, @memory[Runtime::AREA] + (i * 4), size: 32) }
            places.each do |place|
              @asm.mov(:eax, place)
              @asm.push(:eax)
            end
            places.zip(edges) { |place, edge| @asm.mov(place, edge) }
            node.children.each { |child| emit_statement(child) }
            places.reverse_each do |place|
              @asm.pop(:eax)
              @asm.mov(place, :eax)
            end
          end

          # A PATCH OF THE PICTURE, for each one the game declares (a sprite painted into the picture declares
          # the one it keeps what is under it in): room in the data segment for its width and height and a
          # byte a pixel (Runtime::Regions), with the width and height written as the program starts, and a
          # number that is 1 once something has been kept in it.
          def keep_patches
            @patches = @program.walk.select { |node| node.kind == :backing_buffer }.to_h do |node|
              place = @memory.reserve("the patch #{node.name}", 4 + (node.width * node.height), what: "the patch of the picture #{node.name.inspect}")
              @starts << [place, node.width | (node.height << 16)]
              [node.name, [place, @memory.reserve("whether the patch #{node.name} is kept", 4)]]
            end
          end

          def patch_of(name)
            @patches.fetch(name) { raise LoweringError, "the patch of the picture #{name.inspect} is used and never declared" }
          end

          # Reference#exec_save_region: the patch filled from the picture at x and y, off the screen and all.
          def emit_save_region(node)
            place, kept = patch_of(node.buffer)
            emit_values_into(%i[eax ecx], [value_node(node.x), value_node(node.y)])
            @asm.mov(:si, place)
            @asm.call("rt_save_region")
            @asm.mov(X86.mem(nil, kept, size: 32), 1)
          end

          # Reference#exec_restore_region: the patch put back at x and y, and nothing where none was ever kept.
          def emit_restore_region(node)
            place, kept = patch_of(node.buffer)
            nothing_kept = fresh_label("no_patch")
            @asm.cmp(X86.mem(nil, kept, size: 32), 0)
            @asm.je(nothing_kept)
            emit_values_into(%i[eax ecx], [value_node(node.x), value_node(node.y)])
            @asm.mov(:si, place)
            @asm.call("rt_restore_region")
            @asm.label(nothing_kept)
          end

          # The part of the build a game with such a fade waits for, for a test run to count skips by.
          PART_FADE = "a fade of part of the screen (`inside:`, `outside:`, `under:`)"

          # A fade of part of the screen is not a walk of the palette, which changes every pixel there is: how
          # the processor fades some of them is decided when it is made (Console::DOSAnswers, `fade`).
          def refuse_unmade_fades!
            return unless @program.walk.any? { |node| node.kind == :fade && (node.under || node.reaches || node.area) }

            raise NotMadeYet.new("This game fades part of the screen. The #{CONSOLE.title} build does not make that yet. " \
                                 "To fix this, fade the whole screen for now.", part: PART_FADE)
          end

          # Reference#exec_fade and #exec_tint, on a console with no blend: the walk the step asks for
          # (PaletteWalk.walk_for), its steps held to their range, handed to the runtime to work the palette
          # out from as the pass ends (Runtime::Fades).
          def emit_walk(node)
            walk = PaletteWalk.walk_for(node)
            emit_value(walk.steps)
            @asm.mov(:ecx, walk.toward)
            @asm.mov(:edx, walk.color)
            @asm.call("rt_walk")
          end

          # Reference#exec_blit_pose: one of the pictures, by the number the game works out, and nothing
          # for a number that is none of them.
          def emit_blit_pose(node)
            skip = fresh_label("no_pose")
            emit_value(node.index)
            @asm.cmp(:eax, node.poses.size) # as numbers with no sign, so one below nought is too big as well
            @asm.jae(skip)
            emit_picture_from_table(@art_places.fetch(poses_key(node.poses)), node)
            @asm.label(skip)
          end

          # Where the table of places of the pictures +poses+ is kept among the art's places.
          def poses_key(poses) = [:poses, poses]

          # Reference#pixels_overlap?: each side's picture found from its pose, then its x and y, the first side
          # before the second, all pushed for rt_pixels_overlap (Runtime::Overlap), which answers 1 or 0.
          def emit_pixels_overlap(node)
            [[node.a_poses, node.a_pose, node.a_x, node.a_y], [node.b_poses, node.b_pose, node.b_x, node.b_y]].each do |poses, pose, x, y|
              emit_value(pose)
              @asm.mov(:ecx, poses.size)
              @asm.mov(:dx, @art_places.fetch(poses_key(poses)))
              @asm.call("rt_overlap_picture")
              @asm.push(:eax)
              [x, y].each do |operand|
                emit_value(operand)
                @asm.push(:eax)
              end
            end
            @asm.call("rt_pixels_overlap")
          end

          # Whether +program+ asks if two pictures' drawn pixels touch, and so carries Runtime::Overlap.
          def self.overlaps_in?(program) = program.walk.any? { |node| node.kind == :pixels_overlap }

          # The picture whose place is word EAX of the table at +table+ in the art segment, drawn at the node's
          # x and y.
          def emit_picture_from_table(table, node)
            @asm.mov(:bx, :ax)
            @asm.add(:bx, :bx)
            @asm.add(:bx, table)
            @asm.mov_segment(:cx, :art)
            @asm.push(:ds)
            @asm.mov(:ds, :cx)
            @asm.mov(:si, X86.mem(:bx, 0))
            @asm.pop(:ds)
            emit_blit_call(node)
          end

          # Reference#exec_camera: the view put where the game says, for the picture shown to be made with.
          def emit_camera(node)
            emit_operands(node.x, node.y)
            @asm.call("rt_camera")
          end

          # Reference#exec_pixelate: the size of the blocks the picture shown is made in (Runtime::View). Blocks that
          # leave a layer as drawn (`under:`) are a tiled screen's, and the builder refuses them on a painted one.
          def emit_pixelate(node)
            emit_value(node.size)
            @asm.call("rt_pixelate")
          end

          def emit_pixel(node)
            emit_operands(node.x, node.y)
            @asm.mov(:dl, palette_entry(node.color))
            @asm.call("rt_pixel")
          end

          # The same rectangle however the game wrote it (Reference#exec_fill_rect, #exec_dma_fill_rect and
          # #exec_draw_rect_at): x, y, width and height into EAX, ECX, EDX and EBX, the palette entry into SI.
          def emit_rectangle(node)
            emit_values_into(%i[eax ecx edx ebx], [node.x, node.y, node.w, node.h].map { |edge| value_node(edge) })
            @asm.mov(:si, palette_entry(node.color))
            @asm.call("rt_fill_rect")
          end

          # Reference#exec_blit: the picture at x and y, from its place in the art segment.
          def emit_blit(node) = emit_picture_at(@art_places.fetch(node.name), node)

          # Reference#exec_draw_text: the words as a picture in their colour, at x and y. A text with no pixels
          # in its font draws nothing.
          def emit_draw_text(node)
            return emit_picture_at(@art_places.fetch(text_key(node)), node) unless node.picked

            emit_picked_text(node)
          end

          # A text whose colour is picked as it runs (`picked:`): it is kept as a picture in each of its two colours,
          # and drawn in the picked one where its number (`showing:`) is not nought. x and y are worked out first,
          # then the number, as the interpreter works them out.
          def emit_picked_text(node)
            emit_values_into(%i[eax ecx], [value_node(node.x), value_node(node.y)])
            @asm.push(:eax)
            @asm.push(:ecx)
            emit_value(node.showing)
            own = fresh_label("text_own_color")
            @asm.mov(:si, @art_places.fetch(text_key(node)))
            @asm.test(:eax, :eax)
            @asm.je(own)
            @asm.mov(:si, @art_places.fetch(text_key(node, node.picked)))
            @asm.label(own)
            @asm.pop(:ecx)
            @asm.pop(:eax)
            @asm.call("rt_blit")
          end

          # Reference#exec_draw_column_at: where, how tall and which column worked out, then the picture's place and
          # the strip's width, which are settled as the game is built.
          def emit_draw_column_at(node)
            emit_values_into(%i[eax ecx edx ebx], [node.x, node.top, node.height, node.slice].map { |operand| value_node(operand) })
            @asm.mov(:si, @art_places.fetch(node.name))
            @asm.mov(:edi, node.width || 1)
            @asm.call("rt_draw_column")
          end

          # The picture at +place+ in the art segment, drawn at the node's x and y.
          def emit_picture_at(place, node)
            @asm.mov(:si, place)
            emit_blit_call(node)
          end

          # rt_blit with the picture's place already in SI: the node's x into EAX and its y into ECX. Working
          # one out can call a routine that changes SI (a list read), so SI is kept round any that is worked.
          def emit_blit_call(node)
            operands = [value_node(node.x), value_node(node.y)]
            worked = !operands.all? { |operand| simple?(operand) }
            @asm.push(:si) if worked
            emit_values_into(%i[eax ecx], operands)
            @asm.pop(:si) if worked
            @asm.call("rt_blit")
          end

          # Reference#exec_draw_digit: the picture of the digit the value is, picked from the table of ten places
          # (a value outside 0 to 9 draws nothing), at the digit's x and y.
          def emit_draw_digit(node)
            table = @art_places.fetch(digits_key(node))
            skip = fresh_label("no_digit")
            emit_value(node.value)
            @asm.cmp(:eax, 9)
            @asm.ja(skip)
            emit_picture_from_table(table, node)
            @asm.label(skip)
          end

          def value_node(operand) = operand.is_a?(Integer) ? Build.int(operand) : operand

          # +operands+ worked out into +registers+. What needs working out is done first and kept on the stack,
          # since the working uses EAX and ECX; a number or a variable is then loaded straight into its register.
          def emit_values_into(registers, operands)
            worked = registers.zip(operands).reject { |_, operand| simple?(operand) }
            worked.each do |_, operand|
              emit_value(operand)
              @asm.push(:eax)
            end
            registers.zip(operands).each { |register, operand| emit_simple_into(register, operand) if simple?(operand) }
            worked.reverse_each { |register, _| @asm.pop(register) }
          end

          # --- values: worked out into EAX ---

          def emit_value(operand)
            known = folded(operand)
            return @asm.mov(:eax, Int32.wrap(known)) if known

            case operand
            when Symbol then @asm.mov(:eax, number_at(operand))
            when Node then emit_value_of_kind(operand)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def emit_value_of_kind(node)
            case node.kind
            when :int then @asm.mov(:eax, Int32.wrap(node.value))
            when :var_ref then @asm.mov(:eax, number_at(node.name))
            when :binop then emit_binop(node)
            when :neg
              emit_value(node.operand)
              @asm.neg(:eax)
            when :save_read then emit_runtime_call("rt_save_read", node.at, save_width(node))
            when :save_sum then emit_runtime_call("rt_save_sum", node.at, node.length)
            when :clamped then emit_clamped(node.operand, node.min, node.max)
            when :absolute then emit_absolute(node)
            when :bit_not
              emit_value(node.operand)
              @asm.not(:eax)
            when :shift_right then emit_shift_right(node)
            when :mul_fix then emit_mul_fix(node)
            when *Lists::VALUE_KINDS then emit_list_value(node)
            when :chance then emit_chance(node)
            when :data_byte then @asm.mov(:eax, data_byte(node))
            when :table_get then emit_table_get(node)
            when :timer_ticks then @asm.mov(:eax, number_at(timer_ticks_variable(node.name)))
            when :div_fix then emit_div_fix(node)
            when :clock then emit_clock_reading(node)
            # A PC is played by one person, who is player 1 (Console::DOSAnswers).
            when :local_player, :players_connected then @asm.mov(:eax, 1)
            when :pixels_overlap then emit_pixels_overlap(node)
            when :held then emit_button_down_flag(Runtime::Frame::HELD, node.button)
            when :pressed then emit_button_down_flag(Runtime::Frame::PRESSED, node.button)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          # Reference#clamp_value: the number held at the floor, then at the ceiling, in that order, so a
          # floor worked out to above its ceiling gives the ceiling. The number in EAX, the floor in EDX and
          # the ceiling in ECX, compared as signed numbers.
          def emit_clamped(operand, min, max)
            above_floor = fresh_label("above_floor")
            below_ceiling = fresh_label("below_ceiling")
            emit_values_into(%i[eax edx ecx], [operand, min, max].map { |part| value_node(part) })
            @asm.cmp(:eax, :edx)
            @asm.jge(above_floor)
            @asm.mov(:eax, :edx)
            @asm.label(above_floor)
            @asm.cmp(:eax, :ecx)
            @asm.jle(below_ceiling)
            @asm.mov(:eax, :ecx)
            @asm.label(below_ceiling)
          end

          # Reference#exec_clamp: the variable held inside the range, as #emit_clamped holds a number.
          def emit_clamp(node)
            emit_clamped(Build.var_ref(node.var), node.min, node.max)
            emit_store(node.var)
          end

          # Reference#exec_abs and #exec_negate_abs: the variable turned the other way round unless it is already
          # the way wanted: not below nought with +above_nought+, and not above it without.
          def emit_sign_held(name, above_nought:)
            done = fresh_label("sign_held")
            @asm.mov(:eax, number_at(name))
            @asm.test(:eax, :eax)
            above_nought ? @asm.jns(done) : @asm.jle(done)
            @asm.neg(:eax)
            emit_store(name)
            @asm.label(done)
          end

          # Reference#value_of_absolute: how far the number is from nought. The smallest number there is has no
          # other way round and stays as it is, as Int32.neg leaves it.
          def emit_absolute(node)
            done = fresh_label("absolute")
            emit_value(node.operand)
            @asm.test(:eax, :eax)
            @asm.jns(done)
            @asm.neg(:eax)
            @asm.label(done)
          end

          # Reference#value_of_chance: 1 where the number drawn is below the chance in a hundred.
          def emit_chance(node)
            emit_value(node.draw)
            @asm.cmp(:eax, node.percent)
            @asm.setl(:al)
            @asm.movzx(:eax, :al)
          end

          # Reference#data_byte: a byte of data the game declared, which is known as the game is built. One past
          # its end stops the build, where the interpreter stops the run.
          def data_byte(node)
            @data_declared ||= @program.walk.select { |declared| declared.kind == :data }.to_h { |declared| [declared.name, declared.bytes] }
            bytes = @data_declared.fetch(node.name) { raise LoweringError, "the data #{node.name.inspect} is read and never declared" }
            bytes.getbyte(node.index) || raise(LoweringError, "data_byte index #{node.index} is past the end of #{node.name.inspect}")
          end

          # Each table a run reads, in the art segment with the pictures: its entries at the width the plan
          # keeps it at (LoweringPlan#table_keeping), the low byte first.
          def make_tables
            @plan.tables_read.each do |table|
              bytes, = @plan.table_keeping(table)
              @art_places[table_key(table.name)] = @art.bytesize
              @art << table.values.flat_map { |entry| Array.new(bytes) { |i| (Int32.wrap(entry) >> (8 * i)) & 0xFF } }.pack("C*")
            end
          end

          def table_key(name) = [:table, name]

          # Reference#value_of_table_get: the entry at the index made safe (LoweringPlan.index_kept_in_range: a
          # table whose length is a power of two wraps it, any other holds it to the ends), widened to a whole
          # number by its sign or with noughts as the table keeps it. DS is the art segment for the one read.
          def emit_table_get(node)
            table = @plan.tables.fetch(node.name) { raise LoweringError, "the table #{node.name.inspect} is read and never declared" }
            bytes, signed = @plan.table_keeping(table)
            emit_value(LoweringPlan.index_kept_in_range(node.index, table.values.length))
            @asm.mov(:bx, :ax)
            @asm.shl(:bx, bytes.bit_length - 1) if bytes > 1
            @asm.add(:bx, @art_places.fetch(table_key(table.name)))
            @asm.mov_segment(:cx, :art)
            @asm.push(:ds)
            @asm.mov(:ds, :cx)
            emit_table_entry_read(X86.mem(:bx, 0, size: bytes * 8), bytes, signed)
            @asm.pop(:ds)
          end

          # EAX from a table's +entry+ of +bytes+ bytes, widened by its sign or with noughts as the table keeps it.
          def emit_table_entry_read(entry, bytes, signed)
            if bytes == 4 then @asm.mov(:eax, entry)
            elsif signed then @asm.movsx(:eax, entry)
            else @asm.movzx(:eax, entry)
            end
          end

          # Int32.shift_right by a count settled as the game is built: the bits moved down with the sign filling
          # in behind, and a count outside 0 to 31 leaves only the sign.
          def emit_shift_right(node)
            emit_value(node.operand)
            count = Int32.shift_count_in_range?(node.bits) ? node.bits : Int32::BITS - 1
            @asm.sar(:eax, count) unless count.zero?
          end

          # Int32.mul_fix: the whole 64-bit product first, then its bits moved down, so a product too big for
          # 32 bits before the shift is not lost. EDX holds the product's high half and EAX its low.
          def emit_mul_fix(node)
            bits = node.fraction_bits
            raise LoweringError, "a product is moved down by #{bits} bits, and it has none below nought" if bits.negative?

            emit_operands(node.lhs, node.rhs)
            @asm.imul_wide(:ecx)
            return if bits.zero?
            return @asm.shrd(:eax, :edx, bits) if bits < Int32::BITS

            @asm.mov(:eax, :edx)
            moved = [bits - Int32::BITS, Int32::BITS - 1].min
            @asm.sar(:eax, moved) unless moved.zero?
          end

          # Int32.div_fix, by the runtime's routine: the numerator widened by the fraction's bits and then
          # divided, which is more than 32 bits of numerator.
          def emit_div_fix(node)
            bits = node.fraction_bits
            unless bits.between?(0, Int32::BITS)
              raise LoweringError, "a fraction of #{bits} bits is divided, and the #{CONSOLE.title} build divides one of " \
                                   "0 to #{Int32::BITS}"
            end

            emit_operands(node.lhs, node.rhs)
            @asm.mov(:bl, bits)
            @asm.call("rt_div_fix")
          end

          # 1 where +button+ is in the set the runtime keeps at +which+ (held through the pass, or pressed
          # in it), a bit each in IR::Buttons's order; any of the keyboard's for Buttons::ANY. One person
          # plays at a keyboard, and a game that asks for a second player's is refused before it reaches
          # here (Console::DOSAnswers, by #refuse_what_console_lacks!).
          def emit_button_down_flag(which, button)
            mask = button == Buttons::ANY ? Buttons.mask(CONSOLE.buttons) : Buttons.mask(button)
            @asm.mov(:eax, runtime_at(which))
            @asm.test(:eax, mask)
            @asm.setne(:al)
            @asm.movzx(:eax, :al)
          end

          # The left in EAX and the right in ECX, then one instruction on the pair, or a call to the runtime
          # where IR::Int32 and the processor differ (Runtime#emit_number_routines).
          def emit_binop(node)
            return emit_comparison(node) if COMPARISONS.include?(node.op)
            return emit_both_or_either(node) if %i[and or].include?(node.op)

            emit_operands(node.lhs, node.rhs)
            case node.op
            when :+ then @asm.add(:eax, :ecx)
            when :- then @asm.sub(:eax, :ecx)
            when :* then @asm.imul(:eax, :ecx)
            when :& then @asm.and(:eax, :ecx)
            when :| then @asm.or(:eax, :ecx)
            when :^ then @asm.xor(:eax, :ecx)
            when :/ then @asm.call("rt_div32")
            when :% then @asm.call("rt_mod32")
            when :<< then @asm.call("rt_shl32")
            when :>> then @asm.call("rt_shr32")
            else raise LoweringError, "no writer here for the operator #{node.op.inspect}"
            end
          end

          # A comparison is a signed compare, then 1 in AL where it holds (SETcc) widened to EAX.
          def emit_comparison(node)
            emit_operands(node.lhs, node.rhs)
            @asm.cmp(:eax, :ecx)
            case node.op
            when :< then @asm.setl(:al)
            when :<= then @asm.setle(:al)
            when :> then @asm.setg(:al)
            when :>= then @asm.setge(:al)
            when :== then @asm.sete(:al)
            when :!= then @asm.setne(:al)
            else raise LoweringError, "no writer here for the comparison #{node.op.inspect}"
            end
            @asm.movzx(:eax, :al)
          end

          # `and` and `or` work out both sides (no short-circuit, as Reference does), then combine their truth.
          def emit_both_or_either(node)
            emit_operands(node.lhs, node.rhs)
            @asm.test(:eax, :eax)
            @asm.setne(:al)
            @asm.test(:ecx, :ecx)
            @asm.setne(:cl)
            node.op == :and ? @asm.and(:al, :cl) : @asm.or(:al, :cl)
            @asm.movzx(:eax, :al)
          end

          # The left number in EAX and the right in ECX. A right that is a number or a variable is loaded
          # straight into ECX; any other is worked out with the left kept on the stack.
          def emit_operands(left, right)
            emit_value(left)
            if simple?(right)
              emit_simple_into(:ecx, right)
            else
              @asm.push(:eax)
              emit_value(right)
              @asm.mov(:ecx, :eax)
              @asm.pop(:eax)
            end
          end

          def simple?(operand) = !folded(operand).nil? || !variable_named(operand).nil?

          def variable_named(operand)
            return operand if operand.is_a?(Symbol)

            operand.name if operand.is_a?(Node) && operand.kind == :var_ref
          end

          def emit_simple_into(register, operand)
            known = folded(operand)
            return @asm.mov(register, Int32.wrap(known)) if known

            @asm.mov(register, number_at(variable_named(operand)))
          end

          # A condition worked out into EAX, then a jump on whether it is nought.
          def emit_jump_if(condition, label)
            emit_value(condition)
            @asm.test(:eax, :eax)
            @asm.jne(label)
          end

          def emit_jump_unless(condition, label)
            emit_value(condition)
            @asm.test(:eax, :eax)
            @asm.je(label)
          end
        end
      end
    end
  end
end
