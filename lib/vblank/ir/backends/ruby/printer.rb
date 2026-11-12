# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Ruby
        # Turns the statement tree the lowering builds into Ruby: the body of the game's class.
        # The only place in the backend that writes Ruby.
        #
        # The tree has no operators in it: every number a game keeps goes through a runtime
        # function (runtime/rg_int32.rb). What the printer has to know:
        #
        # - A CONDITION IS A NUMBER, nought or not. In Ruby only nil and false are false, so a
        #   number taken as a condition is written as a comparison with nought (`while x != 0`),
        #   never bare, which would always be taken. A comparison taken as one is Ruby's own
        #   comparison (`if a < b`), which is true or false already.
        # - THE GAME'S OWN ARITHMETIC IS WRITTEN AS RUBY'S OPERATORS (INLINE_OPERATORS,
        #   WRAPPED_OPERATORS), each in parentheses, so no precedence is needed. It runs every
        #   frame, and YJIT compiles an operator on small numbers to a few instructions but a
        #   runtime method only as a call: a `+` through rg_add was two calls. A sum, difference or
        #   product that can pass 32 bits keeps its answer in a temporary of its own and calls
        #   rg_i32 to come round only when it has, which a game's numbers nearly never do. The
        #   operands are worked out left to right, as the call worked them out.
        # - WHERE A NAME LIVES. Everything the game keeps — its variables, lists, tables, the
        #   arrays of routines it calls by number, the art the runtime reads — is an instance
        #   variable of the game, set in rg_game_setup; a routine's own locals are Ruby locals.
        # - A ROUTINE IS A METHOD, called by name, and one picked from an array by number is that
        #   array's block calling it by name.
        # - A LONG ROUTINE IS SEVERAL METHODS. Ruby's compiler walks a method's branches by
        #   recursion on the machine's stack, one level for each `if`, `while` or `? :` in the whole
        #   method, so the stack a method needs grows with its length. A thread other than the main
        #   one, and so a Ractor, has a small stack: there a method of about 29,000 plain branches,
        #   or 9,000 sums with their check for coming round, is too long to compile, and Ruby stops
        #   with "stack level too deep" before the game's first line runs (the main thread's stack
        #   holds about seven times that). A data pack's unpacking is long, and is played in a
        #   Ractor (Live::BackgroundUnpacking). So a routine of more than MOST_BRANCHES_A_METHOD is
        #   printed in parts (#print_part_call), each a method of its own, and no method is longer
        #   than that whatever the routine's length. A routine shorter than that is printed whole,
        #   as before, since a call costs a little each time.
        class Printer
          Statements = Computer::Statements
          INDENT = "  "

          # The most numbers a table is written out as; a bigger one is written as base64.
          MOST_WRITTEN_AS_NUMBERS = 256

          # Runtime functions of two numbers written as Ruby's operator: a comparison, 1 or 0 as a
          # number and true or false as a condition, and the bits, which cannot pass 32 bits.
          COMPARISONS = Ractor.make_shareable({ "rg_lt" => "<", "rg_le" => "<=", "rg_gt" => ">", "rg_ge" => ">=",
                                                "rg_eq" => "==", "rg_ne" => "!=" })
          INLINE_OPERATORS = Ractor.make_shareable({ "rg_and" => "&", "rg_or" => "|", "rg_xor" => "^" })
          # ...and the ones that can pass 32 bits, and so come round (rg_i32) when they do.
          WRAPPED_OPERATORS = Ractor.make_shareable({ "rg_add" => "+", "rg_sub" => "-", "rg_mul" => "*" })
          OPERATORS_OF_TWO = Ractor.make_shareable(Set.new(COMPARISONS.keys + INLINE_OPERATORS.keys + WRAPPED_OPERATORS.keys))

          # How each C type a table is kept in packs its numbers into bytes, for a big table
          # written as base64: little-endian, the width the type holds.
          PACKING = Ractor.make_shareable({ "int8_t" => "c*", "uint8_t" => "C*", "char" => "C*",
                                            "int16_t" => "s<*", "uint16_t" => "S<*", "int32_t" => "l<*" })

          # The most branches one printed method holds (#branches_in counts them), well inside what
          # a Ractor's stack compiles (see the class's heading).
          MOST_BRANCHES_A_METHOD = 3_000

          # What a part of a routine hands back to the method that called it, besides nil (it ran
          # to its end, so the caller goes on) and the routine's own 0 or 1 (the routine hands that
          # back at once): that the routine goes on to its next step, leaves its loop, or returns.
          PART_ENDINGS = Ractor.make_shareable({ goto: ":rg_next", break: ":rg_break", return: ":rg_return" })

          # The statements that always leave the method they are printed in, so a part ending in one
          # needs no nil after it.
          LEAVING_STATEMENTS = [Statements::Goto, Statements::Pause, Statements::Finish, Statements::Return].freeze

          # Every function the printed code calls by name, so the build can say which of them the
          # runtime does not have (Lowering#runtime_gaps).
          attr_reader :called

          def initialize
            @out = +""
            @setup = []
            @called = Set.new
            @branches = {}.compare_by_identity
          end

          # The body of the game's class: rg_game_setup, which gives every instance variable its
          # starting value, and then a method for every routine. +items+ is the top level.
          def print_file(items)
            @lists = items.grep(Statements::ListStorage).to_set { |list| list.name.text }
            routines = +""
            @out = routines
            items.each { |item| print_top(item) }
            @out = +""
            line(0, "def rg_game_setup")
            @setup.each { |text| @out << text }
            line(0, "end")
            line(0, "")
            @out << routines
          end

          private

          # --- the top level ---

          def print_top(item)
            case item
            when Statements::Include, Statements::Define, Statements::Prototype then nil # a method is found wherever it is defined
            when Statements::Global then add_starting_value("@#{item.name.text} = #{integer(item.value)}")
            when Statements::ConstArray then print_const_array(item)
            when Statements::StartFileArray then print_start_file_array(item)
            when Statements::Function then print_function(item)
            when Statements::FunctionTable then print_routine_table(item)
            when Statements::ListStorage then add_starting_value("@#{item.name.text} = RgList.build(#{integer(item.capacity)}, #{integer(item.width)}, #{string(item.label)})")
            when Statements::Comment then nil # the tree's own heading; the file has Ruby::WRITTEN_BY
            else raise LoweringError, "the printer has no top-level form for #{item.class}"
            end
          end

          def add_starting_value(text) = @setup << "#{INDENT}#{text}\n"

          # A table of routines picked by number (`call [:a, :b], number: n`): a block for each that
          # calls it by name, made in rg_game_setup so each calls the game's own (#call).
          def print_routine_table(item)
            calls = item.functions.map { |name| "-> { #{name.text} }" }
            add_starting_value("@#{item.name.text} = [#{calls.join(', ')}].freeze")
          end

          def print_function(item)
            @locals = Set.new
            @temporaries = 0
            @routine = item.name.text
            @in_parts = list_branches(item.body) > MOST_BRANCHES_A_METHOD
            @parts = []
            @part_count = 0
            print_method(item.name.text, item.body, part: false)
            print_method(*@parts.shift, part: true) until @parts.empty?
          end

          # One method: the routine itself, or a +part+ of it (#print_part_call), which hands back
          # nil when it runs to its end (a step's part never does: a step ends by leaving).
          #
          # A routine printed in parts hands back nil at its end, where printed whole it hands back
          # the value of its last line, and that is left so: nothing reads it. A routine gives
          # nothing back (Statements::Function) but a resumable one, whose 1 or 0 is always handed
          # back by a `return` (Pause, Finish, or a Resume passing one on), since its steps are a
          # loop that is only ever left that way. A call whose answer is kept (Resume, RunToEnd,
          # and the runtime's `rg_game_main == 1`) is only ever of a resumable routine.
          def print_method(name, body, part:)
            @in_part = part
            @loops_open = 0
            line(0, "def #{name}")
            statements(1, body)
            line(1, "nil") if part && !LEAVING_STATEMENTS.include?(body.last.class)
            line(0, "end")
            line(0, "")
          end

          # A small table is its numbers, sixteen a line. A big one is its bytes in base64, read
          # back when the game starts, which keeps a picture of thousands of pixels to a few lines.
          def print_const_array(item)
            values = item.values.map { |value| integer(value) }
            name = "@#{item.name.text}"
            frozen = item.writable ? "" : ".freeze"
            if values.size > MOST_WRITTEN_AS_NUMBERS
              packing = PACKING.fetch(item.type) { raise LoweringError, "the printer has no packing for C's #{item.type}" }
              bytes = [item.values.pack(packing)].pack("m0")
              add_starting_value("#{name} = #{string(bytes)}.unpack1(\"m\").unpack(#{string(packing)})#{frozen}")
            elsif values.empty?
              add_starting_value("#{name} = [0]#{frozen}")
            else
              rows = values.each_slice(16).map { |row| "#{INDENT * 2}#{row.join(', ')},\n" }.join
              @setup << "#{INDENT}#{name} = [\n#{rows}#{INDENT}]#{frozen}\n"
            end
          end

          # An array the start file fills (Statements::StartFileArray): its size alone, zeros until the runtime
          # puts the file's entries in it.
          def print_start_file_array(item)
            count = integer([item.count, 1].max)
            made = case item.type
                   when "uint8_t" then "RgBytes.new(#{count})"
                   when "int8_t" then "RgSignedBytes.new(#{count})"
                   else "Array.new(#{count}, 0)"
                   end
            add_starting_value("@#{item.name.text} = #{made}")
          end

          # --- statements ---

          # +list+ written out here, or, in a routine printed in parts when +list+ is longer than a
          # method holds, cut: its statements a run at a time into parts, and one too long for a part
          # on its own written here with what it holds in parts (#heavy?).
          def statements(depth, list)
            return list.each { |statement| statement(depth, statement) } unless @in_parts && list_branches(list) > MOST_BRANCHES_A_METHOD

            run = []
            run_branches = 0
            list.each do |statement|
              branches = branches_in(statement)
              if heavy?(statement)
                print_part_call(depth, run)
                run = []
                run_branches = 0
                statement(depth, statement)
              else
                if run_branches + branches > MOST_BRANCHES_A_METHOD
                  print_part_call(depth, run)
                  run = []
                  run_branches = 0
                end
                run << statement
                run_branches += branches
              end
            end
            print_part_call(depth, run)
          end

          # A statement longer than a method holds, in a routine printed in parts: the statements
          # inside it are each put in parts of their own (#inner_statements).
          def heavy?(statement) = @in_parts && branches_in(statement) > MOST_BRANCHES_A_METHOD

          # The statements inside +owner+ (an if's branch, a loop's body, a step).
          def inner_statements(depth, list, owner)
            heavy?(owner) ? print_part_call(depth, list) : statements(depth, list)
          end

          # +list+ as a part of the routine, a method of its own printed after it, and its call here.
          # What the part hands back is handed on (PART_ENDINGS): a part only stops the routine,
          # leaves its loop or goes to the next step through the method it was cut from.
          def print_part_call(depth, list)
            return if list.empty?

            name = "rg_part_#{@part_count += 1}_#{@routine}"
            @parts << [name, list]
            endings = endings_of(list, in_loop: false)
            return line(depth, name) if endings.empty?

            line(depth, "rg_part_ended = #{name}")
            if @in_part
              line(depth, "break if rg_part_ended == #{PART_ENDINGS[:break]}") if endings.include?(:break) && @loops_open.positive?
              line(depth, "return rg_part_ended unless rg_part_ended.nil?")
            else
              line(depth, "next if rg_part_ended == #{PART_ENDINGS[:goto]}") if endings.include?(:goto)
              line(depth, "break if rg_part_ended == #{PART_ENDINGS[:break]}") if endings.include?(:break)
              line(depth, "return if rg_part_ended == #{PART_ENDINGS[:return]}") if endings.include?(:return)
              line(depth, "return rg_part_ended unless rg_part_ended.nil?") if endings.include?(:value)
            end
          end

          # How +list+ can leave the method it is printed in: :goto, :break (of a loop outside it),
          # :return, or :value (the routine's own 0 or 1).
          def endings_of(list, in_loop:)
            list.each_with_object(Set.new) do |statement, endings|
              case statement
              when Statements::Goto then endings << :goto
              when Statements::Pause, Statements::Finish, Statements::Resume then endings << :value
              when Statements::Return then endings << :return
              when Statements::Break then endings << :break unless in_loop
              when Statements::If then endings.merge(endings_of(statement.body, in_loop: in_loop))
                                                .merge(endings_of(statement.otherwise, in_loop: in_loop))
              when Statements::Block then endings.merge(endings_of(statement.body, in_loop: in_loop))
              when Statements::While then endings.merge(endings_of(statement.body, in_loop: true))
              end
            end
          end

          # Leaving the method by +ending+ (PART_ENDINGS): from a part, handing it back; from the
          # routine itself, Ruby's own +word+.
          def leave(depth, ending, word)
            line(depth, @in_part ? "return #{PART_ENDINGS.fetch(ending)}" : word)
          end

          # --- how long a routine is ---

          # The branches +statement+ is printed with, as Ruby's compiler counts its cost: an if, a
          # loop or a comparison taken as a number (`? :`) one each, and a sum with its check for
          # coming round three, its `||` making the branch dearer (measured, see the class's heading).
          def branches_in(statement)
            @branches[statement] ||=
              case statement
              when Statements::Eval then expression_branches(statement.call)
              when Statements::Assign then expression_branches(statement.target) + expression_branches(statement.value)
              when Statements::Local then expression_branches(statement.value)
              when Statements::If
                1 + expression_branches(statement.condition) + list_branches(statement.body) + list_branches(statement.otherwise)
              when Statements::While then 1 + expression_branches(statement.condition) + list_branches(statement.body)
              when Statements::Block then list_branches(statement.body)
              when Statements::Steps then statement.steps.sum { |step| list_branches(step) }
              when Statements::Resume, Statements::RunToEnd then 1 + expression_branches(statement.call)
              else 0
              end
          end

          def list_branches(list) = list.sum { |statement| branches_in(statement) }

          def expression_branches(item)
            case item
            when Statements::Index then expression_branches(item.array) + expression_branches(item.index)
            when Statements::Call
              function = item.function.text
              own = if COMPARISONS.key?(function) then 1
                    elsif WRAPPED_OPERATORS.key?(function) then 3
                    else 0
                    end
              own + item.args.sum { |arg| expression_branches(arg) }
            else 0
            end
          end

          # --- statements ---

          def statement(depth, item)
            case item
            when Statements::Eval then line(depth, expression(item.call))
            when Statements::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)}")
            when Statements::Local then print_local(depth, item)
            when Statements::If then print_if(depth, item)
            when Statements::While then print_while(depth, item)
            when Statements::Break then @loops_open.positive? ? line(depth, "break") : leave(depth, :break, "break")
            when Statements::Return then leave(depth, :return, "return")
            when Statements::Block then statements(depth, item.body) # a Ruby method's locals are its own already
            when Statements::Comment then comment(depth, item.text)
            when Statements::Steps then print_steps(depth, item)
            when Statements::Goto then line(depth, "#{expression(item.counter)} = #{integer(item.step)}")
                              leave(depth, :goto, "next")
            when Statements::Pause then line(depth, "#{expression(item.counter)} = #{integer(item.step)}")
                               line(depth, "return 1")
            when Statements::Finish then line(depth, "#{expression(item.counter)} = 0")
                                line(depth, "return 0")
            when Statements::Resume then line(depth, "return 1 if #{expression(item.call)} == 1")
            when Statements::RunToEnd then print_run_to_end(depth, item)
            else raise LoweringError, "the printer has no statement form for #{item.class}"
            end
          end

          # A resumable routine run from its start for an answer (Statements::RunToEnd): the counters and locals
          # it can reach kept in Ruby locals, the counters set to 0, and all put back after.
          def print_run_to_end(depth, item)
            kept = item.counters + item.locals.map(&:name)
            kept.each_with_index { |name, k| line(depth, "rg_kept_#{k} = #{expression(name)}") }
            item.counters.each { |counter| line(depth, "#{expression(counter)} = 0") }
            line(depth, "rg_wait_vblank_while_answering if #{expression(item.call)} == 1")
            kept.each_with_index { |name, k| line(depth, "#{expression(name)} = rg_kept_#{k}") }
          end

          # A resumable routine's steps (Computer::Resumable): a loop round a case on its counter, each
          # step going on to the next with `next`, and leaving the method with 1 or 0.
          def print_steps(depth, item)
            line(depth, "while true")
            line(depth + 1, "case #{expression(item.counter)}")
            item.steps.each_with_index do |step, number|
              line(depth + 1, "when #{integer(number)}")
              inner_statements(depth + 2, step, item)
            end
            # A counter no step has (none the game writes) ends the routine, as the C does.
            line(depth + 1, "else")
            line(depth + 2, "#{expression(item.counter)} = 0")
            line(depth + 2, "return 0")
            line(depth + 1, "end")
            line(depth, "end")
          end

          # A local is a Ruby local, or, in a routine printed in parts, where every part reads it, an
          # instance variable (the lowering names each local for its routine alone).
          def print_local(depth, item)
            @locals << item.name.text unless @in_parts
            line(depth, "#{name(item.name)} = #{expression(item.value)}")
          end

          def print_if(depth, item)
            line(depth, "if #{condition(item.condition)}")
            inner_statements(depth + 1, item.body, item)
            unless item.otherwise.empty?
              line(depth, "else")
              inner_statements(depth + 1, item.otherwise, item)
            end
            line(depth, "end")
          end

          def print_while(depth, item)
            line(depth, "while #{condition(item.condition)}")
            @loops_open += 1
            inner_statements(depth + 1, item.body, item)
            @loops_open -= 1
            line(depth, "end")
          end

          # A number taken as a condition: not nought; a comparison is one already.
          def condition(item)
            operator = item.is_a?(Statements::Call) && COMPARISONS[item.function.text]
            return "#{expression(item)} != 0" unless operator

            left, right = item.args
            "#{expression(left)} #{operator} #{expression(right)}"
          end

          # --- expressions ---

          def expression(item)
            case item
            when Statements::Int then integer(item.value)
            when Statements::Name then name(item)
            when Statements::AddressOf then address_of(item.name)
            when Statements::Text then string(item.value)
            when Statements::Index then "#{expression(item.array)}[#{expression(item.index)}]"
            when Statements::Call then call(item)
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

          # A local is itself, a constant the runtime declares (RG_FADE_INSIDE) is itself, and
          # anything else the game keeps is an instance variable.
          def name(item)
            text = item.text
            @locals.include?(text) || text.start_with?("RG_") ? text : "@#{text}"
          end

          # A routine picked from an array by its number (rg_call_routine(table[which])) is that
          # array's block for it (#print_routine_table), called.
          def call(item)
            function = item.function.text
            return "#{expression(item.args.first)}.call" if function == "rg_call_routine"
            return operator_of_two(item) if item.args.size == 2 && OPERATORS_OF_TWO.include?(function)

            @called << function
            "#{function}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
          end

          # A runtime function of two numbers written as Ruby's operator (see the class's heading).
          def operator_of_two(item)
            function = item.function.text
            left, right = item.args.map { |arg| expression(arg) }
            if (compared = COMPARISONS[function])
              "(#{left} #{compared} #{right} ? 1 : 0)"
            elsif (bits = INLINE_OPERATORS[function])
              "(#{left} #{bits} #{right})"
            else
              @called << "rg_i32"
              kept = "w_#{@temporaries += 1}"
              "((#{kept} = #{left} #{WRAPPED_OPERATORS.fetch(function)} #{right}) > #{Int32::MAX} || " \
                "#{kept} < #{Int32::MIN} ? rg_i32(#{kept}) : #{kept})"
            end
          end

          # Where a global lives, for a runtime function that reads it later. A list is an object,
          # handed over as itself; a number is not, so a variable is handed over as a lambda that
          # reads it then.
          def address_of(name)
            @lists.include?(name.text) ? "@#{name.text}" : "-> { @#{name.text} }"
          end

          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value.to_s
          end

          # A Ruby string, every character outside plain ASCII escaped and nothing in it read as
          # code (String#dump escapes a # that would start an interpolation).
          def string(text) = text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).dump

          def comment(depth, text) = line(depth, "# #{text.to_s.tr("\n", ' ')}")

          def line(depth, text)
            @out << (INDENT * depth) << text << "\n"
          end
        end
      end
    end
  end
end
