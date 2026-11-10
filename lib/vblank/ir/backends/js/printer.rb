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
            items.each { |item| print_top(item) }
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
            when Statements::Include, Statements::Prototype then nil # JavaScript finds a function wherever it is declared
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
            line(0, "function #{item.name.text}() {")
            statements(1, item.body)
            line(0, "}")
            line(0, "")
          end

          # A small table is its numbers, sixteen a line, as the C writes it. A big one is its
          # bytes in base64, read back when the script starts (rg_table_from_base64 says why: a
          # browser runs out of memory reading millions of numbers written out as code).
          def print_const_array(item)
            type = ARRAYS.fetch(item.type) { raise LoweringError, "the printer has no array for C's #{item.type}" }
            values = item.values
            if values.empty?
              line(0, "const #{item.name.text} = new #{type}(1);")
            elsif values.size > MOST_WRITTEN_AS_NUMBERS && @data == :separate
              print_table_in_data_file(item.name.text, type, values)
            elsif values.size > MOST_WRITTEN_AS_NUMBERS
              print_table_as_base64(item.name.text, type, values)
            else
              line(0, "const #{item.name.text} = new #{type}([")
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
          def print_table_as_base64(name, type, values)
            line(0, "const #{name} = rg_table_from_base64(#{type}, `")
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

          def statements(depth, list)
            list.each { |statement| statement(depth, statement) }
          end

          def statement(depth, item)
            case item
            when Statements::Eval then print_eval(depth, item.call)
            when Statements::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)};")
            when Statements::Local then line(depth, "let #{item.name.text} = #{expression(item.value)};")
            when Statements::If then print_if(depth, item)
            when Statements::While then print_block_statement(depth, "while (#{expression(item.condition)}) {", item.body)
            when Statements::Break then line(depth, "break;")
            when Statements::Return then line(depth, "return;")
            when Statements::Block then print_block_statement(depth, "{", item.body)
            when Statements::Comment then comment(depth, item.text)
            when Statements::Steps then print_steps(depth, item)
            when Statements::Goto then line(depth, "#{item.counter.text} = #{integer(item.step)}; continue;")
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
            line(depth, "for (;;) {")
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
            line(depth, "if (#{expression(item.condition)}) {")
            statements(depth + 1, item.body)
            unless item.otherwise.empty?
              line(depth, "} else {")
              statements(depth + 1, item.otherwise)
            end
            line(depth, "}")
          end

          def print_block_statement(depth, opening, body)
            line(depth, opening)
            statements(depth + 1, body)
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
            when Statements::Call then "#{item.function.text}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

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
