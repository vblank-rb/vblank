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
        # its conditions and halting, and a painted screen of one page with a cleared screen and pixels, in
        # a palette of the colours the game names. Everything else is refused by name until it is made
        # (NOT_LOWERED_YET), and what a PC cannot do at all is refused in the words its answers have
        # (Console::Answers#refusals).
        class Lowering
          # A program refused because it reaches something the build does not make yet, with the +part+ of
          # the build that is missing, for a test run to count skips by.
          class NotMadeYet < LoweringError
            include Backends::NotMadeYet
          end

          # EVERY KIND THIS LOWERING WRITES, each by a method called by name in #emit_statement and
          # #value_of_kind. A declaration writes nothing where it is.
          STATEMENT_KINDS = (%i[
            program set add sub copy if loop repeat halt wait_vblank screen clear_screen pixel
          ] + Nodes.of_role(:declaration)).freeze

          VALUE_KINDS = %i[int var_ref binop neg].freeze

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

          # The binops one instruction does on EAX and ECX, the routines that do the others, and the
          # conditions a comparison asks the processor for.
          IN_PLACE = Ractor.make_shareable({ :+ => :add, :- => :sub, :& => :and, :| => :or, :^ => :xor })
          CALLED = Ractor.make_shareable({ :/ => "rt_div32", :% => "rt_mod32", :<< => "rt_shl32", :>> => "rt_shr32" })
          CONDITIONS = Ractor.make_shareable({ :< => :l, :<= => :le, :> => :g, :>= => :ge, :== => :e, :!= => :ne })

          # What the build works out once for every try (BuildCache#facts). The DOS build makes one try, so
          # there is nothing of its own to keep.
          class BuildFacts
            def initialize(_cache); end
          end

          # Where each variable went (its offset in the data segment), by its name, the palette the screen is
          # drawn in (15-bit colours, entry 0 black), and what starts as something other than nought.
          attr_reader :variables, :palette, :starts

          def initialize(program, memory:, cache: BuildCache.for(DOS, program))
            @program = program
            @memory = memory
            @plan = cache.plan
            @variables = {}
            @locals = {}
            @starts = []
            @labels = 0
            @routine = MAIN
          end

          # Writes the game's code, as the routine MAIN, into +asm+ (an X86).
          def emit(asm)
            @asm = asm
            refuse_what_cannot_be_made!
            reserve_variables
            @palette = palette_of(@program)
            keep_loop_running
            @asm.label(MAIN)
            @program.children.each { |node| statement(node) }
            @asm.ret
          end

          private

          def refuse_what_cannot_be_made!
            Backends.refuse_start_file_on_cartridge!(@program, @plan.console, LoweringError)
            @plan.refuse_hardware_only_kinds!
            @plan.refuse_kinds_not_made_yet!(NOT_LOWERED_YET, NotMadeYet)
            @plan.refuse_routines_that_call_themselves!
            @plan.refuse_what_console_lacks!
            refuse_unmade_screens!
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

          def loop_variables = @plan.game_loops.flat_map { |node| console_loop(node).variables }

          def reserve_variables
            (Reach.variables(@program) | loop_variables).each do |name|
              @variables[name] = @memory.reserve(name, 4, what: "the variable #{name.inspect}")
            end
          end

          # The colours the game names, as the 15-bit numbers the interpreter paints with, after black.
          def palette_of(program)
            colors = program.walk.select { |node| %i[clear_screen pixel].include?(node.kind) }
                            .map { |node| Graphics::Color.resolve(node.color) }.uniq - [0]
            if colors.size > CONSOLE.list_colors - 1
              raise LoweringError, "This game paints with #{colors.size} colours. DOS shows #{CONSOLE.list_colors} at once, " \
                                   "one of them black. To fix this, use fewer colours."
            end
            [0, *colors]
          end

          def palette_entry(color) = @palette.index(Graphics::Color.resolve(color))

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

          def number_at(name) = X86.mem(nil, place_of(name))
          def runtime_at(name) = X86.mem(nil, @memory[name])

          def console_loop(node) = @plan.console_loop(node)
          def folded(node) = @plan.folded(node)

          # --- statements ---

          def statement(node)
            case node.kind
            when :program then node.children.each { |child| statement(child) }
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
            return (known.zero? ? otherwise : body).each { |child| statement(child) } if known

            other = fresh_label("else")
            done = fresh_label("end_if")
            jump_unless(node.cond, other)
            body.each { |child| statement(child) }
            @asm.jmp(done) unless otherwise.empty?
            @asm.label(other)
            otherwise.each { |child| statement(child) }
            @asm.label(done)
          end

          def emit_loop(node)
            console_loop(node).before.each { |child| statement(child) }
            emit_number_into(@loop_running, (loops_ending_passes.index(node) || -1) + 1) if @loop_running
            top = fresh_label("loop")
            @asm.label(top)
            console_loop(node).each_time.each { |child| statement(child) }
            @asm.jmp(top)
          end

          # The game loops that end each pass by placing the display's writes (IR::Frames::ConsoleLoop#pass_end),
          # which a halt has to end as the running one does; and which of those is running, counted from 1.
          def loops_ending_passes = (@loops_ending_passes ||= @plan.game_loops.select { |node| console_loop(node).pass_end.any? })

          def keep_loop_running = (@loop_running = keep_local(:loop_running) if loops_ending_passes.any?)

          def emit_number_into(name, number)
            @asm.mov_memory_number(number_at(name), Int32.wrap(number) & 0xFFFF_FFFF, size: 32)
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
            jump_unless(Build.binop(:<, Build.var_ref(index), count), done)
            if node.index
              @asm.mov(:eax, number_at(index))
              emit_store(node.index)
            end
            jump_if(node.stop_when, done)
            node.children.each { |child| statement(child) }
            emit_sum(index, :+, Build.int(1))
            @asm.jmp(top)
            @asm.label(done)
          end

          def emit_halt
            loops_ending_passes.each_with_index do |ending, i|
              other = fresh_label("not_this_loop")
              jump_unless(Build.binop(:==, Build.var_ref(@loop_running), Build.int(i + 1)), other)
              console_loop(ending).pass_end.each { |child| statement(child) }
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
            with_operands(node.x, node.y)
            @asm.mov(:dl, palette_entry(node.color))
            @asm.call("rt_pixel")
          end

          # --- values: worked out into EAX ---

          def emit_value(operand)
            known = folded(operand)
            return @asm.mov(:eax, Int32.wrap(known)) if known

            case operand
            when Symbol then @asm.mov(:eax, number_at(operand))
            when Node then value_of_kind(operand)
            else raise LoweringError, "cannot make #{operand.inspect} a number"
            end
          end

          def value_of_kind(node)
            case node.kind
            when :int then @asm.mov(:eax, Int32.wrap(node.value))
            when :var_ref then @asm.mov(:eax, number_at(node.name))
            when :binop then value_of_binop(node)
            when :neg
              emit_value(node.operand)
              @asm.neg(:eax)
            else raise LoweringError, "no writer here for #{node.kind.inspect}"
            end
          end

          def value_of_binop(node)
            return value_of_comparison(node) if CONDITIONS.key?(node.op)
            return value_of_both_or_either(node) if %i[and or].include?(node.op)

            with_operands(node.lhs, node.rhs)
            if CALLED.key?(node.op)
              @asm.call(CALLED.fetch(node.op))
            elsif node.op == :*
              @asm.imul(:eax, :ecx)
            else
              @asm.public_send(IN_PLACE.fetch(node.op), :eax, :ecx)
            end
          end

          def value_of_comparison(node)
            with_operands(node.lhs, node.rhs)
            @asm.cmp(:eax, :ecx)
            @asm.public_send(:"set#{CONDITIONS.fetch(node.op)}", :al)
            @asm.movzx(:eax, :al)
          end

          # `and` and `or` work out both sides (no short-circuit, as Reference does), then combine their truth.
          def value_of_both_or_either(node)
            with_operands(node.lhs, node.rhs)
            @asm.test(:eax, :eax)
            @asm.setne(:al)
            @asm.test(:ecx, :ecx)
            @asm.setne(:cl)
            node.op == :and ? @asm.and(:al, :cl) : @asm.or(:al, :cl)
            @asm.movzx(:eax, :al)
          end

          # The left number in EAX and the right in ECX. A right that is a number or a variable is loaded
          # straight into ECX; any other is worked out with the left kept on the stack.
          def with_operands(left, right)
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
          def jump_if(condition, label)
            emit_value(condition)
            @asm.test(:eax, :eax)
            @asm.jne(label)
          end

          def jump_unless(condition, label)
            emit_value(condition)
            @asm.test(:eax, :eax)
            @asm.je(label)
          end
        end
      end
    end
  end
end
