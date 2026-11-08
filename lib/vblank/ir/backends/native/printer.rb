# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Native
        # Turns the C syntax tree (C) into text. The only place in the backend that writes C.
        class Printer
          INDENT = "  "

          # The most numbers a table of bytes is written out as. A bigger one is kept in a file of
          # its own that the C embeds (#embedded): a game's recordings can be tens of millions of
          # bytes, which as numbers in the text take long to write and far longer to compile.
          MOST_WRITTEN_AS_NUMBERS = 4096

          # The tables kept in a file of their own, by their type: how their numbers are packed into
          # bytes, and the numbers that fit.
          EmbeddedType = Data.define(:packing, :range)
          EMBEDDED_TYPES = Ractor.make_shareable({ "int8_t" => EmbeddedType.new(packing: "c*", range: -128..127),
                                                   "uint8_t" => EmbeddedType.new(packing: "C*", range: 0..255) })

          # The bytes of each table kept in a file of its own, by the file's name, which the C
          # embeds it from: written beside game.c wherever the text is (Lowering#source_files).
          # The name is the bytes' fingerprint, so two programs that differ in a table differ in
          # their text too.
          attr_reader :embedded

          def initialize
            @out = +""
            @embedded = {}
          end

          # The whole file: +items+ is the top level, in the order it is to appear.
          def print_file(items)
            items.each { |item| print_top(item) }
            @out
          end

          private

          def print_top(item)
            case item
            when C::Include then line(0, "#include \"#{item.header}\"")
            when C::Global then line(0, "static #{item.type} #{item.name.text} = #{expression(C::Int.new(item.value))};")
            when C::ConstArray then print_const_array(item)
            when C::ConstGlobal then print_const_global(item)
            # Zeros until the start file fills it: a static array with no initializer.
            when C::StartFileArray then line(0, "static #{item.type} #{item.name.text}[#{[item.count, 1].max}];")
            when C::Prototype then line(0, "#{linkage(item)}void #{item.name.text}(void);")
            when C::Function then print_function(item)
            when C::FunctionTable then print_function_table(item)
            when C::ListStorage then print_list_storage(item)
            when C::Comment then comment(0, item.text)
            else raise LoweringError, "the printer has no top-level form for #{item.class}"
            end
          end

          def linkage(item) = item.exported ? "" : "static "

          def print_function(item)
            line(0, "#{linkage(item)}void #{item.name.text}(void) {")
            statements(1, item.body)
            line(0, "}")
            line(0, "")
          end

          # Sixteen numbers a line, so a table of thousands is still a file a person can scroll. A big
          # table of bytes is kept in a file of its own (#print_embedded_array).
          def print_const_array(item)
            embedded = EMBEDDED_TYPES[item.type]
            if embedded && item.values.size > MOST_WRITTEN_AS_NUMBERS && item.values.all?(Integer)
              return print_embedded_array(item, embedded)
            end

            line(0, "#{linkage(item)}const #{item.type} #{item.name.text}[#{[item.values.size, 1].max}] = {")
            # C has no empty initializer, so an array with no values holds one zero (its size is 1).
            values = item.values.empty? ? [0] : item.values
            values.each_slice(16) { |row| line(1, "#{row.map { |value| array_value(value) }.join(', ')},") }
            line(0, "};")
          end

          # A big table of bytes, read by the compiler from a file beside game.c (C's #embed), which is
          # far quicker to write and to compile than its numbers. #embed is C23's and the runtime is
          # compiled as C11 with every warning an error, so the warning that says so is turned off
          # around this table alone. A number that does not fit the type is refused, as a number
          # written out is (#integer).
          def print_embedded_array(item, embedded)
            low, high = item.values.minmax
            unless embedded.range.cover?(low) && embedded.range.cover?(high)
              raise LoweringError, "the table #{item.name.text} holds #{low}..#{high}, which does not fit #{item.type}"
            end

            bytes = item.values.pack(embedded.packing)
            file = "rg_embed_#{Digest::SHA256.hexdigest(bytes)[0, 16]}.bin"
            @embedded[file] = bytes
            line(0, "#pragma clang diagnostic push")
            line(0, "#pragma clang diagnostic ignored \"-Wc23-extensions\"")
            line(0, "#{linkage(item)}const #{item.type} #{item.name.text}[#{item.values.size}] = {")
            line(0, "#embed \"#{file}\"")
            line(0, "};")
            line(0, "#pragma clang diagnostic pop")
          end

          # A number, or a Struct for an array of them.
          def array_value(value) = value.is_a?(Integer) ? integer(value) : expression(value)

          def print_const_global(item)
            line(0, "#{linkage(item)}const #{item.type} #{item.name.text} = #{expression(item.value)};")
          end

          def print_function_table(item)
            line(0, "static void (*const #{item.name.text}[#{item.functions.size}])(void) = {")
            item.functions.each { |function| line(1, "#{function.text},") }
            line(0, "};")
          end

          def print_list_storage(item)
            capacity = integer(item.capacity)
            line(0, "static int32_t #{item.items.text}[#{capacity}];")
            line(0, "static rg_list #{item.name.text} = { #{item.items.text}, #{capacity}, " \
                    "#{integer(item.width)}, 0, 0, #{string(item.label)} };")
          end

          def statements(depth, list)
            list.each { |statement| statement(depth, statement) }
          end

          def statement(depth, item)
            case item
            when C::Eval then line(depth, "#{expression(item.call)};")
            when C::Assign then line(depth, "#{expression(item.target)} = #{expression(item.value)};")
            when C::Local then line(depth, "#{item.type} #{item.name.text} = #{expression(item.value)};")
            when C::If then print_if(depth, item)
            when C::While then print_while(depth, item)
            when C::Break then line(depth, "break;")
            when C::Return then line(depth, "return;")
            when C::Block then print_block(depth, item)
            when C::Comment then comment(depth, item.text)
            else raise LoweringError, "the printer has no statement form for #{item.class}"
            end
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

          def print_while(depth, item)
            line(depth, "while (#{expression(item.condition)}) {")
            statements(depth + 1, item.body)
            line(depth, "}")
          end

          def print_block(depth, item)
            line(depth, "{")
            statements(depth + 1, item.body)
            line(depth, "}")
          end

          def expression(item)
            case item
            when C::Int then integer(item.value)
            when C::Name then item.text
            when C::AddressOf then "&#{item.name.text}"
            when C::Text then string(item.value)
            when C::Struct then "{#{item.fields.map { |field, value| ".#{field} = #{expression(value)}" }.join(', ')}}"
            when C::Index then "#{expression(item.array)}[#{expression(item.index)}]"
            when C::Call then "#{item.function.text}(#{item.args.map { |arg| expression(arg) }.join(', ')})"
            else raise LoweringError, "the printer has no expression form for #{item.class}"
            end
          end

          # A whole number, written so C reads it as a 32-bit one. The lowest of them cannot be
          # written as -2147483648: C reads that as 2147483648 (too big for an int, so a wider
          # kind) with a minus in front, which is why <stdint.h> has INT32_MIN.
          def integer(value)
            unless value.is_a?(Integer) && value.between?(Int32::MIN, Int32::MAX)
              raise LoweringError, "#{value.inspect} is not a 32-bit whole number, so it cannot be written as one"
            end

            value == Int32::MIN ? "INT32_MIN" : value.to_s
          end

          # A C string: anything outside plain printable ASCII, and the two characters with a
          # meaning of their own inside quotes, written as an escape.
          def string(text)
            body = text.b.each_byte.map do |byte|
              char = byte.chr
              if char == '"' || char == "\\" then "\\#{char}"
              elsif byte.between?(0x20, 0x7E) then char
              else format("\\%03o", byte)
              end
            end
            "\"#{body.join}\""
          end

          # A comment can hold anything except the sequence that ends it, so each "*/" is
          # broken up; and it is kept to the one line, so a line break becomes a space.
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
