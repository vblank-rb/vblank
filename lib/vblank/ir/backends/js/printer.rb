# frozen_string_literal: true

require "json"

module VBlank
  module IR
    module Backends
      class JS
        # Turns the statement tree the lowering builds (Computer::Statements) into JavaScript. The only place
        # in the backend that writes JavaScript.
        #
        # The tree has no operators in it — every number a game keeps goes through a runtime
        # function (runtime/rg_int32.js) — so nothing here has to know JavaScript's precedence, or
        # that its numbers are 64-bit floats.
        #
        # WAITING FOR A FRAME. A browser cannot stop a script part way: a page that never gives
        # control back never shows a picture. Every routine that can reach a wait is resumable
        # (Computer::Resumable): it gives back 1 when it stops for a frame and carries on from its own
        # counter when called again, so the driver plays the game by calling rg_game_main once a
        # frame, and the browser keeps control between frames, with the place the game has reached
        # kept in its globals, which a save state can write.
        #
        # THE GAME'S OWN ARITHMETIC IS WRITTEN AS JAVASCRIPT'S OPERATORS (OPERATORS, SHIFTS), each
        # the runtime function's body with its numbers put in, so V8 need not inline a call for every
        # number a game works out: in a long function it inlines only some of them.
        #
        # A LONG ROUTINE IS SEVERAL FUNCTIONS. V8 optimises a function only while its bytecode is
        # under a limit (--max-optimized-bytecode-size); one past it runs
        # in V8's interpreter for good. A data pack's unpacking is all one routine, unrolled as the
        # port's Ruby builds it, and printed whole its rg_game_main was hundreds of thousands of lines,
        # which ran a port's unpacking many times slower than its C. So a routine heavier than
        # MOST_WEIGHT_A_FUNCTION (#weight_of) is printed in parts (#print_part_call), each a function of
        # its own lighter than that, as the Ruby printer cuts one for Ruby's own limits; its locals are
        # variables beside it, which every part reads. A resumable one keeps its steps in groups of
        # functions too (#print_steps_in_groups), so the loop a routine goes round with a wait in it
        # runs inside one function V8 optimises, not in the routine's switch of thousands of steps.
        class Printer
          Statements = Computer::Statements
          INDENT = "  "

          # The JavaScript typed array each C type a table or a picture is kept in becomes.
          ARRAYS = Ractor.make_shareable({ "int8_t" => "Int8Array", "uint8_t" => "Uint8Array",
                                           "int16_t" => "Int16Array", "uint16_t" => "Uint16Array",
                                           "int32_t" => "Int32Array", "char" => "Uint8Array" })

          # The most numbers a table is written out as; a bigger one is written as base64.
          MOST_WRITTEN_AS_NUMBERS = 256

          # How many bytes of a data file's fingerprint it starts with (see #data_file).
          DATA_STAMP_BYTES = 8

          # How each array's numbers are packed into bytes: little-endian, the width the array holds.
          PACKING = Ractor.make_shareable({ "Int8Array" => "c*", "Uint8Array" => "C*", "Int16Array" => "s<*",
                                            "Uint16Array" => "S<*", "Int32Array" => "l<*" })

          # The runtime's call of a routine picked from an array.
          CALL_ROUTINE = "rg_call_routine"

          # The runtime's functions of two numbers written as JavaScript's own operators, each the
          # function's body in runtime/rg_int32.js with the two numbers put in: what goes before the
          # first, between the two, and after the second. Both are worked out, left first, as the
          # call worked them out; `&` of two tests, not `&&`, so the second is never skipped.
          OPERATORS = Ractor.make_shareable({
                                              "rg_add" => ["((", " + ", ") | 0)"], "rg_sub" => ["((", " - ", ") | 0)"],
                                              "rg_mul" => ["Math.imul(", ", ", ")"],
                                              "rg_and" => ["(", " & ", ")"], "rg_or" => ["(", " | ", ")"], "rg_xor" => ["(", " ^ ", ")"],
                                              "rg_lt" => ["(", " < ", " ? 1 : 0)"], "rg_le" => ["(", " <= ", " ? 1 : 0)"],
                                              "rg_gt" => ["(", " > ", " ? 1 : 0)"], "rg_ge" => ["(", " >= ", " ? 1 : 0)"],
                                              "rg_eq" => ["(", " === ", " ? 1 : 0)"], "rg_ne" => ["(", " !== ", " ? 1 : 0)"],
                                              "rg_both" => ["((", " !== 0) & (", " !== 0))"],
                                              "rg_either" => ["((", " !== 0) | (", " !== 0))"]
                                            })

          # The runtime's shifts, written as JavaScript's where the count is a number from 0 to 31.
          SHIFTS = Ractor.make_shareable({ "rg_shl" => "<<", "rg_shr" => ">>" })

          # The heaviest one printed function is (#weight_of), well inside what V8 optimises (see
          # "A LONG ROUTINE" in the class's heading).
          MOST_WEIGHT_A_FUNCTION = 2_000

          # What a part of a routine gives back to the function that called it, besides nothing (it
          # ran to its end, so the caller goes on) and the routine's own 0 or 1 (the routine gives
          # that back at once): that the routine goes on to its next step, leaves its loop, or returns.
          PART_ENDINGS = Ractor.make_shareable({ goto: -1, break: -2, return: -3 })

          # A routine in parts keeps its steps in groups of this many (#print_steps_in_groups), the
          # group a step is in being its number shifted down by STEP_GROUP_BITS.
          STEP_GROUP_BITS = 6
          STEPS_A_GROUP = 1 << STEP_GROUP_BITS

          # A part of a routine (#print_part_call): its function's name and the statements in it.
          Part = Data.define(:name, :body)

          # A group of a routine's steps (#print_steps_in_groups): its function's name, its steps, the
          # number of its first, and the name of the routine's counter.
          StepGroup = Data.define(:name, :steps, :first, :counter)

          # +data+ is where a big table's numbers go: :inline, in the file as base64, or :separate, in
          # a data file of their own (#data_file), which the runtime fetches and hands to
          # rg_data_fill before the game's first frame.
          def initialize(data: :inline)
            raise ArgumentError, "data is :inline or :separate, not #{data.inspect}" unless %i[inline separate].include?(data)

            @out = +""
            @data = data
            @payload = +"".b
            @fills = []
          end

          # The whole file: +items+ is the top level, in the order it is to appear.
          def print_file(items)
            @lists = items.grep(Statements::ListStorage).to_set { |list| list.name.text }
            @step_tables = []
            items.each { |item| print_top(item) }
            @step_tables.each { |table| line(0, table) }
            print_data_fill unless @fills.empty?
            @out
          end

          # THE DATA FILE, with the data separate: a fingerprint of what it holds (DATA_STAMP_BYTES
          # of its SHA-256), then every big table's bytes one after another. The file's script
          # holds the same fingerprint and refuses a data file without it, so a data file left
          # from another build of the game is said to be one rather than played as this one's.
          # Nil with the data inline, and for a game with no table big enough to go there, which
          # then fetches nothing.
          def data_file
            return nil if @fills.empty?

            stamp + @payload
          end

          private

          # --- the top level ---

          def print_top(item)
            case item
            when Statements::Include, Statements::Define, Statements::Prototype then nil # JavaScript finds a function wherever it is declared
            when Statements::Global then line(0, "let #{item.name.text} = #{integer(item.value)};")
            when Statements::ConstArray then print_const_array(item)
            when Statements::StartFileArray then print_start_file_array(item)
            when Statements::Function then print_function(item)
            when Statements::FunctionTable then line(0, "const #{item.name.text} = [#{item.functions.map(&:text).join(', ')}];")
            when Statements::ListStorage then print_list_storage(item)
            when Statements::Comment then comment(0, item.text)
            else raise LoweringError, "the printer has no top-level form for #{item.class}"
            end
          end

          def print_function(item)
            @routine = item.name.text
            @in_parts = list_weight(item.body) > MOST_WEIGHT_A_FUNCTION
            @parts = []
            @groups = []
            @part_count = 0
            @hoisted = Set.new
            print_routine_function(item.name.text, item.body, part: false)
            print_step_group(@groups.shift) until @groups.empty?
            until @parts.empty?
              part = @parts.shift
              print_routine_function(part.name, part.body, part: true)
            end
            @hoisted.each { |name| line(0, "let #{name} = 0;") }
            @in_parts = false
          end

          # A routine in parts keeps its steps in groups of STEPS_A_GROUP, each group a function with
          # a loop round a switch of its own (#print_step_group), and the routine itself only picks
          # the group the counter is in: so the loop a game goes round, step after step, is inside a
          # function V8 optimises rather than in a switch of thousands of cases it never does. A step
          # in another group is reached by giving back PART_ENDINGS[:goto] to the routine.
          def print_steps_in_groups(depth, item)
            counter = item.counter.text
            names = item.steps.each_slice(STEPS_A_GROUP).with_index.map do |steps, group|
              name = "rg_steps_#{group}_#{@routine}"
              @groups << StepGroup.new(name: name, steps: steps, first: group * STEPS_A_GROUP, counter: item.counter.text)
              name
            end
            table = "rg_step_groups_#{@routine}"
            @step_tables << "const #{table} = [#{names.join(', ')}];"
            line(depth, "for (;;) {")
            # A counter no step has (none the game writes) ends the routine, as the switch's default
            # does when the steps are printed whole; read unsigned, a negative one is past them too.
            line(depth + 1, "if ((#{counter} >>> 0) >= #{integer(item.steps.size)}) { #{counter} = 0; return 0; }")
            line(depth + 1, "const rg_ended = #{table}[#{counter} >>> #{STEP_GROUP_BITS}]();")
            line(depth + 1, "if (rg_ended === #{PART_ENDINGS[:goto]}) continue;")
            line(depth + 1, "if (rg_ended === #{PART_ENDINGS[:return]}) return;")
            line(depth + 1, "return rg_ended;")
            line(depth, "}")
          end

          # One group of a routine's steps, numbered from +first+: a loop round a switch on the
          # counter, as the routine's own steps were, giving back PART_ENDINGS[:goto] for a step that
          # is not in it.
          # Each step is a part of its own, so the group's switch stays small whatever its steps hold.
          def print_step_group(group)
            @in_part = false
            @loops_open = 0
            line(0, "function #{group.name}() {")
            line(1, "for (;;) {")
            line(2, "switch (#{group.counter}) {")
            group.steps.each_with_index do |step, number|
              line(2, "case #{integer(group.first + number)}:")
              print_part_call(3, step)
            end
            line(2, "default: return #{PART_ENDINGS[:goto]};")
            line(2, "}")
            line(1, "}")
            line(0, "}")
            line(0, "")
          end

          # One function: the routine itself, or a +part+ of it (#print_part_call), which gives back
          # nothing when it runs to its end.
          def print_routine_function(name, body, part:)
            @in_part = part
            @loops_open = 0
            line(0, "function #{name}() {")
            statements(1, body)
            line(0, "}")
            line(0, "")
          end

          # --- a long routine in parts ---

          # How heavy +statement+ is to V8: one for it and one for each call, index and name in it,
          # and the statements it holds. Measured on the tree, as the printed text follows it.
          def weight_of(statement)
            (@weights ||= {}.compare_by_identity)[statement] ||=
              case statement
              when Statements::Eval then 1 + expression_weight(statement.call)
              when Statements::Assign then 1 + expression_weight(statement.target) + expression_weight(statement.value)
              when Statements::Local then 1 + expression_weight(statement.value)
              when Statements::If
                1 + expression_weight(statement.condition) + list_weight(statement.body) + list_weight(statement.otherwise)
              when Statements::While then 1 + expression_weight(statement.condition) + list_weight(statement.body)
              when Statements::Block then list_weight(statement.body)
              when Statements::Steps then statement.steps.sum { |step| 1 + list_weight(step) }
              when Statements::Resume, Statements::RunToEnd then 1 + expression_weight(statement.call)
              else 1
              end
          end

          def list_weight(list) = list.sum { |statement| weight_of(statement) }

          def expression_weight(item)
            case item
            when Statements::Index then 1 + expression_weight(item.array) + expression_weight(item.index)
            when Statements::Call then 1 + item.args.sum { |arg| expression_weight(arg) }
            else 1
            end
          end

          # +list+ written out here, or, in a routine printed in parts when +list+ is heavier than a
          # function V8 optimises, cut: its statements a run at a time into parts, and one too heavy
          # for a part on its own written here with what it holds in parts (#heavy?).
          def statements(depth, list)
            return list.each { |statement| statement(depth, statement) } unless @in_parts && list_weight(list) > MOST_WEIGHT_A_FUNCTION

            run = []
            run_weight = 0
            list.each do |statement|
              weight = weight_of(statement)
              if heavy?(statement)
                print_part_call(depth, run)
                run = []
                run_weight = 0
                statement(depth, statement)
              else
                if run_weight + weight > MOST_WEIGHT_A_FUNCTION
                  print_part_call(depth, run)
                  run = []
                  run_weight = 0
                end
                run << statement
                run_weight += weight
              end
            end
            print_part_call(depth, run)
          end

          # A statement heavier than a function holds, in a routine printed in parts: the statements
          # inside it are each put in parts of their own (#inner_statements).
          # A routine's steps always stay in the routine itself, round which their loop goes.
          def heavy?(statement) = @in_parts && (statement.is_a?(Statements::Steps) || weight_of(statement) > MOST_WEIGHT_A_FUNCTION)

          # The statements inside +owner+ (an if's branch, a loop's body, a step).
          def inner_statements(depth, list, owner)
            heavy?(owner) ? print_part_call(depth, list) : statements(depth, list)
          end

          # +list+ as a part of the routine, a function of its own printed after it, and its call
          # here. What the part gives back is handed on (PART_ENDINGS): a part only stops the
          # routine, leaves its loop or goes to the next step through the function it was cut from.
          def print_part_call(depth, list)
            return if list.empty?

            name = "rg_part_#{@part_count += 1}_#{@routine}"
            @parts << Part.new(name: name, body: list)
            endings = endings_of(list, in_loop: false)
            return line(depth, "#{name}();") if endings.empty?

            ended = "rg_ended_#{@part_count}"
            line(depth, "const #{ended} = #{name}();")
            if @in_part
              line(depth, "if (#{ended} === #{PART_ENDINGS[:break]}) break;") if endings.include?(:break) && @loops_open.positive?
              line(depth, "if (#{ended} !== undefined) return #{ended};")
            else
              line(depth, "if (#{ended} === #{PART_ENDINGS[:goto]}) continue;") if endings.include?(:goto)
              line(depth, "if (#{ended} === #{PART_ENDINGS[:break]}) break;") if endings.include?(:break)
              line(depth, "if (#{ended} === #{PART_ENDINGS[:return]}) return;") if endings.include?(:return)
              line(depth, "if (#{ended} !== undefined) return #{ended};") if endings.include?(:value)
            end
          end

          # How +list+ can leave the function it is printed in: :goto, :break (of a loop outside it),
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

          # Leaving the function by +ending+ (PART_ENDINGS): from a part, giving it back; from the
          # routine itself, JavaScript's own +word+.
          def leave(depth, ending, word)
            line(depth, @in_part ? "return #{PART_ENDINGS.fetch(ending)};" : word)
          end

          # A small table is its numbers, sixteen a line, as the C writes it. A big one is its
          # bytes in base64, read back when the script starts (rg_table_from_base64 says why: a
          # browser runs out of memory reading millions of numbers written out as code).
          #
          # One the runtime makes longer as the game starts (ConstArray#grows) is declared with `let`,
          # so the runtime can name a longer one by it.
          def print_const_array(item)
            type = ARRAYS.fetch(item.type) { raise LoweringError, "the printer has no array for C's #{item.type}" }
            values = item.values
            declared = item.grows ? "let" : "const"
            if values.empty?
              line(0, "#{declared} #{item.name.text} = new #{type}(1);")
            elsif values.size > MOST_WRITTEN_AS_NUMBERS && item.all_zeros?
              # Zeros alone, until the start file fills them (ConstArray#all_zeros?): a typed array
              # starts as zeros, so it is made at its size, with no bytes written or read.
              line(0, "#{declared} #{item.name.text} = new #{type}(#{values.size});")
            elsif values.size > MOST_WRITTEN_AS_NUMBERS && @data == :separate
              print_table_in_data_file(item.name.text, type, values)
            elsif values.size > MOST_WRITTEN_AS_NUMBERS
              print_table_as_base64(item.name.text, type, values, declared)
            else
              line(0, "#{declared} #{item.name.text} = new #{type}([")
              values.each_slice(16) { |row| line(1, "#{row.map { |v| integer(v) }.join(', ')},") }
              line(0, "]);")
            end
          end

          # An array the start file fills (Statements::StartFileArray): its size alone, zeros until then.
          def print_start_file_array(item)
            type = ARRAYS.fetch(item.type) { raise LoweringError, "the printer has no array for C's #{item.type}" }
            line(0, "const #{item.name.text} = new #{type}(#{[item.count, 1].max});")
          end

          # The table's bytes in a template string, 76 characters a line, so the file stays one a
          # person can scroll. Base64 holds no backtick and no `${`, so nothing in it is read as
          # anything but text.
          def print_table_as_base64(name, type, values, declared)
            line(0, "#{declared} #{name} = rg_table_from_base64(#{type}, `")
            [packed_bytes(type, values)].pack("m76").each_line { |row| @out << row }
            line(0, "`);")
          end

          # A table whose bytes are in the data file: empty until rg_data_fill puts them in, which is
          # before anything reads it, since no frame is played until the data is in.
          def print_table_in_data_file(name, type, values)
            @fills << "#{name} = rg_table_from_bytes(#{type}, bytes, #{@payload.bytesize + DATA_STAMP_BYTES}, #{values.size});"
            @payload << packed_bytes(type, values)
            line(0, "let #{name} = null;")
          end

          # +values+ as the bytes of an array of +type+, little-endian; a value that is not a 32-bit
          # whole number is refused, as it is anywhere else in the file (#integer).
          def packed_bytes(type, values)
            values.each { |value| integer(value) }
            values.pack(PACKING.fetch(type))
          end

          def print_data_fill
            line(0, "const RG_DATA_STAMP = #{string(stamp.unpack1('H*'))};")
            line(0, "function rg_data_fill(bytes) {")
            @fills.each { |fill| line(1, fill) }
            line(0, "}")
          end

          def stamp = Digest::SHA256.digest(@payload)[0, DATA_STAMP_BYTES]

          def print_list_storage(item)
            line(0, "const #{item.name.text} = rg_list_new(#{integer(item.capacity)}, #{integer(item.width)}, " \
                    "#{string(item.label)});")
          end

          # --- statements ---

          def statement(depth, item)
            case item
            when Statements::Eval then print_eval(depth, item.call)
            when Statements::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)};")
            when Statements::Local then print_local(depth, item)
            when Statements::If then print_if(depth, item)
            when Statements::While then print_while(depth, item)
            when Statements::Break then @loops_open.positive? || !@in_part ? line(depth, "break;") : leave(depth, :break, "break;")
            when Statements::Return then leave(depth, :return, "return;")
            when Statements::Block then print_block(depth, item)
            when Statements::Comment then comment(depth, item.text)
            when Statements::Steps then print_steps(depth, item)
            when Statements::Goto then line(depth, "#{item.counter.text} = #{integer(item.step)};")
                              leave(depth, :goto, "continue;")
            when Statements::Pause then line(depth, "#{item.counter.text} = #{integer(item.step)}; return 1;")
            when Statements::Finish then line(depth, "#{item.counter.text} = 0; return 0;")
            when Statements::Resume then line(depth, "if (#{routine_call(item.call)}) return 1;")
            when Statements::RunToEnd then print_run_to_end(depth, item)
            else raise LoweringError, "the printer has no statement form for #{item.class}"
            end
          end

          # A call written as a statement. One picked from an array is the array's routine, called.
          def print_eval(depth, call) = line(depth, "#{routine_call(call)};")

          def routine_call(call)
            return "#{expression(call.args.first)}()" if call.function.text == CALL_ROUTINE

            expression(call)
          end

          # A resumable routine run from its start for an answer (Statements::RunToEnd), in a block of its own:
          # the counters and locals it can reach kept, the counters set to 0, and all put back after.
          def print_run_to_end(depth, item)
            kept = item.counters + item.locals.map(&:name)
            line(depth, "{")
            kept.each_with_index { |name, k| line(depth + 1, "const rg_kept_#{k} = #{name.text};") }
            item.counters.each { |counter| line(depth + 1, "#{counter.text} = 0;") }
            line(depth + 1, "if (#{routine_call(item.call)}) rg_wait_vblank_while_answering();")
            kept.each_with_index { |name, k| line(depth + 1, "#{name.text} = rg_kept_#{k};") }
            line(depth, "}")
          end

          # A resumable routine's steps (Computer::Resumable): a loop round a switch on its counter,
          # each step going on with `continue` and leaving the routine with 1 or 0.
          def print_steps(depth, item)
            return print_steps_in_groups(depth, item) if @in_parts

            line(depth, "for (;;) {")
            line(depth + 1, "switch (#{item.counter.text}) {")
            item.steps.each_with_index do |step, number|
              line(depth + 1, "case #{integer(number)}:")
              inner_statements(depth + 2, step, item)
            end
            line(depth + 1, "default: #{item.counter.text} = 0; return 0;")
            line(depth + 1, "}")
            line(depth, "}")
          end

          # A local is a `let` of the function, or, in a routine printed in parts, where every part
          # reads it, a variable beside the routine, declared once after it (the lowering names each
          # local for its routine alone).
          def print_local(depth, item)
            return line(depth, "let #{item.name.text} = #{expression(item.value)};") unless @in_parts

            @hoisted << item.name.text
            line(depth, "#{item.name.text} = #{expression(item.value)};")
          end

          def print_if(depth, item)
            line(depth, "if (#{expression(item.condition)}) {")
            inner_statements(depth + 1, item.body, item)
            unless item.otherwise.empty?
              line(depth, "} else {")
              inner_statements(depth + 1, item.otherwise, item)
            end
            line(depth, "}")
          end

          def print_while(depth, item)
            line(depth, "while (#{expression(item.condition)}) {")
            @loops_open += 1
            inner_statements(depth + 1, item.body, item)
            @loops_open -= 1
            line(depth, "}")
          end

          def print_block(depth, item)
            line(depth, "{")
            inner_statements(depth + 1, item.body, item)
            line(depth, "}")
          end

          # --- expressions ---

          def expression(item)
            case item
            when Statements::Int then integer(item.value)
            when Statements::Name then item.text
            when Statements::AddressOf then address_of(item.name)
            when Statements::Text then string(item.value)
            when Statements::Index then "#{expression(item.array)}[#{expression(item.index)}]"
            when Statements::Call then call_expression(item)
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

          # A call of the runtime, or one of its arithmetic written as JavaScript's own operator
          # (OPERATORS, and a shift by a count written in the game), which is the function's body
          # with its two numbers put in (runtime/rg_int32.js).
          def call_expression(item)
            function = item.function.text
            args = item.args.map { |arg| expression(arg) }
            if args.size == 2 && (form = OPERATORS[function])
              before, between, after = form
              "#{before}#{args.first}#{between}#{args.last}#{after}"
            elsif args.size == 2 && SHIFTS.key?(function) && fixed_shift?(item.args.last)
              "(#{args.first} #{SHIFTS.fetch(function)} #{args.last})"
            else
              "#{function}(#{args.join(', ')})"
            end
          end

          # A shift count written in the game as a number JavaScript's own shift takes as it is: its
          # shifts keep only a count's low five bits, where the runtime's empty the number past 31.
          def fixed_shift?(count) = count.is_a?(Statements::Int) && count.value.between?(0, 31)

          # Where a global lives, for a runtime function that reads it later. A list is an object,
          # handed over as itself. JavaScript has no address of a number, so a variable is handed
          # over as a function that reads it now.
          def address_of(name)
            @lists.include?(name.text) ? name.text : "() => #{name.text}"
          end

          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value.to_s
          end

          # A JavaScript string, every character outside plain ASCII escaped, which JSON's rules do.
          def string(text) = JSON.generate(text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace),
                                           ascii_only: true, script_safe: true)

          # A comment can hold anything except the sequence that ends it, so each "*/" is broken up;
          # and it is kept to the one line.
          def comment(depth, text)
            line(depth, "/* #{text.to_s.gsub('*/', '* /').tr("\n", ' ')} */")
          end

          def line(depth, text)
            @out << (INDENT * depth) << text << "\n"
          end
        end
      end
    end
  end
end
