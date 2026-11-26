# frozen_string_literal: true

require "json"

module VBlank
  module IR
    module Backends
      class Flash
        # Turns the statement tree the lowering builds (Computer::Statements) into Haxe: the body of the
        # class the movie is made of (see Flash#class_text). The only place in the backend that writes Haxe.
        #
        # The tree has no operators in it — every number a game keeps goes through a runtime function
        # (runtime/rg_int32.hx) — so nothing here has to know Haxe's precedence, or that its Int is the
        # movie's 32-bit one.
        #
        # Waiting for a frame. A movie cannot stop a routine part way: Flash gives control back only when
        # a handler ends. Every routine that can reach a wait is resumable (Computer::Resumable): it gives
        # back 1 when it stops for a frame and carries on from its own counter when called again, so the
        # driver plays the game by calling rg_game_main once a frame. The routine's steps are a loop round a
        # switch on its counter.
        class Printer
          Statements = Computer::Statements
          INDENT = "  "

          # The most numbers a table is written out as; a bigger one is written as base64.
          MOST_WRITTEN_AS_NUMBERS = 256

          # How each array's numbers are packed into bytes: little-endian, the width the array holds.
          PACKING = Ractor.make_shareable({ "int8_t" => "c*", "uint8_t" => "C*", "char" => "C*", "int16_t" => "s<*",
                                            "uint16_t" => "S<*", "int32_t" => "l<*" })

          # The runtime functions the printed game calls, and the names of its own routines: what
          # Lowering#runtime_gaps holds the runtime to.
          attr_reader :called, :own

          def initialize
            @out = +""
            @called = Set.new
            @own = Set.new
          end

          # The whole class body: +items+ is the top level, in the order it is to appear.
          def print_file(items)
            @own.merge(items.grep(Statements::Function).map { |function| function.name.text })
            @lists = items.grep(Statements::ListStorage).to_set { |list| list.name.text }
            items.each { |item| print_top(item) }
            @out
          end

          private

          # --- the top level ---

          def print_top(item)
            case item
            when Statements::Include, Statements::Define, Statements::Prototype then nil # Haxe finds a function wherever it is declared
            when Statements::Global then line(0, "static var #{item.name.text}:Int = #{integer(item.value)};")
            when Statements::ConstArray then print_const_array(item)
            when Statements::StartFileArray
              line(0, "static var #{item.name.text}:Vector<Int> = new Vector<Int>(#{[item.count, 1].max});")
            when Statements::Function then print_function(item)
            when Statements::FunctionTable
              kind = item.resumable ? "Void -> Int" : "Void -> Void"
              line(0, "static var #{item.name.text}:Array<#{kind}> = [#{item.functions.map(&:text).join(', ')}];")
            when Statements::ListStorage
              line(0, "static var #{item.name.text}:RgList = rg_list_new(#{integer(item.capacity)}, #{integer(item.width)}, " \
                      "#{string(item.label)});")
            when Statements::Comment then comment(0, item.text)
            else raise LoweringError, "the Flash printer has no top-level form for #{item.class}"
            end
          end

          def print_function(item)
            @resumable = item.resumable
            line(0, "static function #{item.name.text}():#{item.resumable ? 'Int' : 'Void'} {")
            statements(1, item.body)
            line(0, "}")
            line(0, "")
          end

          # A table is its numbers, sixteen a line. A big one is its bytes in base64, read back when the
          # movie starts (rg_table_from_base64).
          def print_const_array(item)
            values = item.values
            name = item.name.text
            if values.empty?
              line(0, "static var #{name}:Vector<Int> = new Vector<Int>(1);")
            elsif values.size > MOST_WRITTEN_AS_NUMBERS && item.all_zeros?
              line(0, "static var #{name}:Vector<Int> = new Vector<Int>(#{values.size});")
            elsif values.size > MOST_WRITTEN_AS_NUMBERS
              values.each { |value| integer(value) }
              packed = [values.pack(PACKING.fetch(item.type) { raise LoweringError, "the Flash printer has no array for C's #{item.type}" })].pack("m0")
              line(0, "static var #{name}:Vector<Int> = rg_table_from_base64(#{string(item.type)}, #{string(packed)});")
            else
              line(0, "static var #{name}:Vector<Int> = Vector.fromArrayCopy([")
              values.each_slice(16) { |row| line(1, "#{row.map { |value| integer(value) }.join(', ')},") }
              line(0, "]);")
            end
          end

          # --- statements ---

          def statements(depth, list) = list.each { |item| statement(depth, item) }

          def statement(depth, item)
            case item
            when Statements::Eval then line(depth, "#{routine_call(item.call)};")
            when Statements::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)};")
            when Statements::Local then line(depth, "var #{item.name.text}:Int = #{expression(item.value)};")
            when Statements::If then print_if(depth, item)
            when Statements::While then print_while(depth, item)
            when Statements::Break then line(depth, "break;")
            when Statements::Continue then line(depth, "continue;")
            when Statements::Return then line(depth, @resumable ? "return 0;" : "return;")
            when Statements::Block then print_block(depth, item)
            when Statements::Comment then comment(depth, item.text)
            when Statements::Steps then print_steps(depth, item)
            when Statements::Goto
              line(depth, "#{item.counter.text} = #{integer(item.step)};")
              line(depth, "continue;")
            when Statements::Pause then line(depth, "#{item.counter.text} = #{integer(item.step)}; return 1;")
            when Statements::Finish then line(depth, "#{item.counter.text} = 0; return 0;")
            when Statements::Resume then line(depth, "if (#{routine_call(item.call)} != 0) return 1;")
            when Statements::RunToEnd then print_run_to_end(depth, item)
            else raise LoweringError, "the Flash printer has no statement form for #{item.class}"
            end
          end

          # A call. One picked from an array is the array's routine, called.
          def routine_call(call)
            return "#{expression(call.args.first)}()" if call.function.text == "rg_call_routine"

            expression(call)
          end

          # A resumable routine run from its start for an answer (Statements::RunToEnd), in a block of its own:
          # the counters and locals it can reach kept, the counters set to 0, and all put back after.
          def print_run_to_end(depth, item)
            kept = item.counters + item.locals.map(&:name)
            line(depth, "{")
            kept.each_with_index { |name, k| line(depth + 1, "var rg_kept_#{k}:Int = #{name.text};") }
            item.counters.each { |counter| line(depth + 1, "#{counter.text} = 0;") }
            line(depth + 1, "if (#{routine_call(item.call)} != 0) rg_wait_vblank_while_answering();")
            kept.each_with_index { |name, k| line(depth + 1, "#{name.text} = rg_kept_#{k};") }
            line(depth, "}")
          end

          # A resumable routine's steps (Computer::Resumable): a loop round a switch on its counter, each
          # step going on with `continue` and leaving the routine with 1 or 0.
          def print_steps(depth, item)
            line(depth, "while (true) {")
            line(depth + 1, "switch (#{item.counter.text}) {")
            item.steps.each_with_index do |step, number|
              line(depth + 1, "case #{integer(number)}:")
              statements(depth + 2, step)
            end
            line(depth + 1, "default: #{item.counter.text} = 0; return 0;")
            line(depth + 1, "}")
            line(depth, "}")
          end

          def print_if(depth, item)
            line(depth, "if (#{expression(item.condition)} != 0) {")
            statements(depth + 1, item.body)
            unless item.otherwise.empty?
              line(depth, "} else {")
              statements(depth + 1, item.otherwise)
            end
            line(depth, "}")
          end

          def print_while(depth, item)
            line(depth, "while (#{expression(item.condition)} != 0) {")
            statements(depth + 1, item.body)
            line(depth, "}")
          end

          def print_block(depth, item)
            line(depth, "{")
            statements(depth + 1, item.body)
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
            when Statements::Call
              @called << item.function.text
              "#{item.function.text}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
            else raise LoweringError, "the Flash printer has no expression form for #{item.class}"
            end
          end

          # Where a global lives, for a runtime function that reads it later. A list is an object, handed
          # over as itself. A number has no address, so a variable is handed over as a function that reads it now.
          def address_of(name) = @lists.include?(name.text) ? name.text : "function():Int { return #{name.text}; }"

          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value.to_s
          end

          # A Haxe string, every character outside plain ASCII escaped. A double-quoted Haxe string takes the
          # same escapes JSON's do, and reads no `$` as anything.
          def string(text) = JSON.generate(text.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace), ascii_only: true)

          # A comment can hold anything except the sequence that ends it, so each "*/" is broken up; and it
          # is kept to the one line.
          def comment(depth, text) = line(depth, "/* #{text.to_s.gsub('*/', '* /').tr("\n", ' ')} */")

          def line(depth, text) = @out << (INDENT * depth) << text << "\n"
        end
      end
    end
  end
end
