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
        # its conditions and halting, the keyboard's keys as buttons, and a painted screen of one page with a cleared screen, pixels,
        # rectangles, pictures (`blit`), text and numbers, in a palette of the colours the game names.
        # Everything else is refused by name until it is made (NOT_LOWERED_YET), and what a PC cannot do at
        # all is refused in the words its answers have (Console::Answers#refusals).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the +part+ of
          # the build that is missing, for a test run to count skips by.
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          # EVERY KIND THIS LOWERING WRITES, each by a method called by name in #emit_statement and
          # #emit_value_of_kind. A declaration writes nothing where it is.
          STATEMENT_KINDS = (%i[
            program set add sub copy if loop repeat halt wait_vblank screen clear_screen pixel fill_rect dma_fill_rect
            draw_rect_at blit draw_text draw_digit
          ] + Nodes.of_role(:declaration)).freeze

          VALUE_KINDS = %i[int var_ref binop neg held pressed].freeze

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

          def pictures? = !@art_places.empty?

          def initialize(program, memory:, cache: BuildCache.for(DOS, program))
            @program = program
            @memory = memory
            @cache = cache
            @plan = cache.plan
            @variables = {}
            @locals = {}
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
            keep_loop_running
            @asm.label(MAIN)
            @program.children.each { |node| emit_statement(node) }
            @asm.ret
          end

          private

          def refuse_what_cannot_be_made!
            Backends.refuse_start_file_on_cartridge!(@program, @plan.console, LoweringError)
            @plan.refuse_hardware_only_kinds!
            @plan.refuse_kinds_not_made_yet!(NOT_LOWERED_YET, NotMadeYet)
            @plan.refuse_routines_that_call_themselves!
            @plan.refuse_what_console_lacks!
            refuse_unmade_variant!
            refuse_unmade_screens!
            refuse_unmade_text!
          end

          # The part of the build a game with a screen variant waits for, for a test run to count skips by.
          VARIANT_PART = "the 320 × 240 and 640 × 480 screens (variants: { dos: :mode_x } and :vesa_640x480)"

          # A variant's screen (Console::DOSKit::DOS_VARIANTS) is not made yet: the program would set mode 13h and
          # draw 200 rows while the game is told it has the variant's. So a game that names one is refused.
          def refuse_unmade_variant!
            return unless @program.variant

            variant = Console.for(:dos).variant(@program.variant)
            raise NotMadeYet.new("This game is for #{CONSOLE.title} with #{variant.title}. The #{CONSOLE.title} build " \
                                 "cannot make that screen yet. To fix this, remove dos: from variants: or from " \
                                 "--variant. The game is then built for the 320 × 200 screen.",
                                 part: VARIANT_PART)
          end

          # A screen drawn from tiles, or one that keeps two pictures (`tear_free: true`), is not made yet.
          def refuse_unmade_screens!
            @program.walk.each do |node|
              next unless node.kind == :screen
              next if node.mode == :bitmap && !node.buffered

              raise NotMadeYet.new("This game shows a screen of tiles or a tear-free screen. The #{CONSOLE.title} build " \
                                   "does not make that yet. To fix this, use `screen :bitmap` for now.",
                                   part: Console::DOSAnswers::NOT_MADE_YET_PART)
            end
          end

          # A text whose colour is picked as the game runs (`picked:`) is two pictures and a choice, which is not
          # made yet.
          def refuse_unmade_text!
            return unless @program.walk.any? { |node| node.kind == :draw_text && node.picked }

            raise NotMadeYet.new("This game writes text in a colour it picks as it runs. The #{CONSOLE.title} build " \
                                 "does not make that yet. To fix this, give the text one colour for now.",
                                 part: Console::DOSAnswers::NOT_MADE_YET_PART)
          end

          def loop_variables = @plan.game_loops.flat_map { |node| console_loop(node).variables }

          def reserve_variables
            (Reach.variables(@program) | loop_variables).each do |name|
              @variables[name] = @memory.reserve(name, 4, what: "the variable #{name.inspect}")
            end
          end

          # The colours the game names, as the 15-bit numbers the interpreter paints with, after black.
          def palette_of(program)
            colors = program.walk.select { |node| PAINTING_KINDS.include?(node.kind) }
                            .map { |node| Graphics::Color.resolve(node.color) }.uniq - [0]
            colors |= drawn_pictures.flat_map { |name| picture_colors(name) } - [0]
            if colors.size >= TRANSPARENT_ENTRY
              raise LoweringError, "This game paints with #{colors.size} colours besides black. DOS shows " \
                                   "#{TRANSPARENT_ENTRY - 1} at once. To fix this, use fewer colours."
            end
            [0, *colors]
          end

          # The palette entry that means "nothing here" in a picture, so no colour is given it.
          TRANSPARENT_ENTRY = Runtime::TRANSPARENT

          def drawn_pictures = @program.walk.select { |node| node.kind == :blit }.map(&:name).uniq

          def picture_node(name)
            @pictures_declared ||= @program.walk.select { |node| node.kind == :bitmap }.to_h { |node| [node.name, node] }
            @pictures_declared.fetch(name) { raise LoweringError, "the picture #{name.inspect} is drawn and never declared" }
          end

          def make_text_pictures
            @program.walk.select { |node| node.kind == :draw_text }.each do |node|
              key = text_key(node)
              @art_places[key] = picture_of_text(node.fonts.get(node.font), node.text, node.color) unless @art_places.key?(key)
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

          def text_key(node) = [:text, node.text, node.font, Graphics::Color.resolve(node.color)]

          def picture_image(name) = (@images ||= {})[name] ||= @cache.image(picture_node(name))

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
          def folded(node) = @plan.folded(node)

          # --- statements ---

          def emit_statement(node)
            case node.kind
            when :program then node.children.each { |child| emit_statement(child) }
            when :set then emit_set(node)
            when :add then emit_sum(node.var, :+, node.operand)
            when :sub then emit_sum(node.var, :-, node.operand)
            when :copy then emit_copy(node)
            when :if then emit_if(node)
            when :loop then emit_loop(node)
            when :repeat then emit_repeat(node)
            when :halt then emit_halt
            when :wait_vblank then emit_wait_vblank
            when :screen then nil # mode 13h is set at power-on, and a screen of one page is all there is
            when :clear_screen then emit_clear_screen(node)
            when :pixel then emit_pixel(node)
            when :fill_rect, :dma_fill_rect, :draw_rect_at then emit_rectangle(node)
            when :blit then emit_blit(node)
            when :draw_text then emit_draw_text(node)
            when :draw_digit then emit_draw_digit(node)
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

          def emit_if(node)
            body = node.children
            otherwise = node.else&.children || []
            known = folded(node.cond)
            return (known.zero? ? otherwise : body).each { |child| emit_statement(child) } if known

            other = fresh_label("else")
            done = fresh_label("end_if")
            emit_jump_unless(node.cond, other)
            body.each { |child| emit_statement(child) }
            @asm.jmp(done) unless otherwise.empty?
            @asm.label(other)
            otherwise.each { |child| emit_statement(child) }
            @asm.label(done)
          end

          def emit_loop(node)
            console_loop(node).before.each { |child| emit_statement(child) }
            emit_number_into(@loop_running, (loops_ending_passes.index(node) || -1) + 1) if @loop_running
            top = fresh_label("loop")
            @asm.label(top)
            console_loop(node).each_time.each { |child| emit_statement(child) }
            @asm.jmp(top)
          end

          # The game loops that end each pass by placing the display's writes (IR::Frames::ConsoleLoop#pass_end),
          # which a halt has to end as the running one does; and which of those is running, counted from 1.
          def loops_ending_passes = (@loops_ending_passes ||= @plan.game_loops.select { |node| console_loop(node).pass_end.any? })

          def keep_loop_running = (@loop_running = keep_local(:loop_running) if loops_ending_passes.any?)

          def emit_number_into(name, number)
            @asm.mov(number_at(name), Int32.wrap(number) & 0xFFFF_FFFF)
          end

          # Reference#exec_repeat: the count worked out once, before the first pass; the index counting 0, 1,
          # 2... and stored in the game's variable at the top of each pass; and +stop_when+ asked BEFORE the
          # body, so a loop already finished on its first pass runs the body no times.
          def emit_repeat(node)
            known = folded(node.count)
            index = keep_local(:index)
            count = known ? Build.int(known) : Build.var_ref(keep_local(:count))
            unless known
              emit_value(node.count)
              emit_store(count.name)
            end
            emit_number_into(index, 0)
            top = fresh_label("repeat")
            done = fresh_label("end_repeat")
            @asm.label(top)
            emit_jump_unless(Build.binop(:<, Build.var_ref(index), count), done)
            if node.index
              @asm.mov(:eax, number_at(index))
              emit_store(node.index)
            end
            emit_jump_if(node.stop_when, done)
            node.children.each { |child| emit_statement(child) }
            emit_sum(index, :+, Build.int(1))
            @asm.jmp(top)
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
            return unless @variables.key?(Frames::COUNT)

            @asm.mov(:eax, number_at(Frames::COUNT))
            @asm.add(:eax, runtime_at(Runtime::Frame::FRAMES_TAKEN))
            emit_store(Frames::COUNT)
            emit_store(Frames::SEEN)
            @asm.mov(:eax, runtime_at(Runtime::Frame::STEP_TAKEN))
            emit_store(Frames::STEP)
          end

          # --- the screen ---

          # A colour as four pixels of its palette entry, which the whole-screen fill stores a word at a time.
          def emit_clear_screen(node)
            @asm.mov(:eax, palette_entry(node.color) * 0x0101_0101)
            @asm.call("rt_clear_screen")
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
          def emit_draw_text(node) = emit_picture_at(@art_places.fetch(text_key(node)), node)

          # The picture at +place+ in the art segment, drawn at the node's x and y.
          def emit_picture_at(place, node)
            @asm.mov(:si, place)
            emit_blit_call(node)
          end

          # rt_blit with the picture's place already in SI: the node's x into EAX and its y into ECX. Working
          # them out never touches SI.
          def emit_blit_call(node)
            emit_values_into(%i[eax ecx], [value_node(node.x), value_node(node.y)])
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
            @asm.mov(:bx, :ax)
            @asm.add(:bx, :bx)
            @asm.add(:bx, table)
            @asm.mov_segment(:cx, :art)
            @asm.push(:ds)
            @asm.mov(:ds, :cx)
            @asm.mov(:si, X86.mem(:bx, 0))
            @asm.pop(:ds)
            emit_blit_call(node)
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
            when :held then emit_button_down_flag(Runtime::Frame::HELD, node.button)
            when :pressed then emit_button_down_flag(Runtime::Frame::PRESSED, node.button)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
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
