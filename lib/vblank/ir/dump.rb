# frozen_string_literal: true

module VBlank
  module IR
    # Turn an IR tree back into Ruby SOURCE that reconstructs it — the inverse of
    # building one. `vblank build --format=ir` uses this to hand back a runnable,
    # self-contained Ruby file holding a game's IR, for inspecting or bisecting the
    # compiler without a ROM in the way.
    #
    # GENERIC OVER EVERY KIND, on purpose: it reads whatever operands and children a
    # node actually carries (Node#attrs, Node#children) rather than knowing kind by
    # kind what those are, so a new IR feature needs nothing added here to be dumped
    # — the same reason {Node#to_h} and {Node#walk} need nothing either.
    #
    # It emits calls to {Nodes.build} (the plain, mechanical "kind symbol + operand
    # hash" constructor) rather than {Build}'s terser sugar (`Build.set`, `Build.if_`,
    # ...): the sugar methods wrap bare literals into value nodes, choose which
    # arguments become children versus operands, and generally don't map onto a
    # node's STORED shape one-for-one. `Nodes.build` does — an operand hash is
    # exactly what {Node#attrs} hands back — so it round-trips exactly, for any kind,
    # with one method.
    module Dump
      INDENT = "  "

      module_function

      # +node+'s Ruby source: a `Nodes.build(:kind, ...)` call, its nested value
      # operands and children spelled out the same way, recursively. Not indented on
      # its own first line (the caller is already mid-line); every line after the
      # first is indented +level+ steps deeper so nested children read as nested code.
      def source(node, level: 0)
        args = arg_list(node, level)
        return "VBlank::IR::Nodes.build(:#{node.kind})" if args.empty?

        "VBlank::IR::Nodes.build(:#{node.kind}, #{args.join(', ')})"
      end

      # This node's operands as `name: value` source fragments, plus a trailing
      # `children: [...]` when it has any — always last, so a reader sees a node's
      # own settings before its nested statements.
      def arg_list(node, level)
        args = node.attrs.map { |name, value| "#{name}: #{value_source(value, level)}" }
        args << children_source(node.children, level) unless node.children.empty?
        args
      end

      # `children: [` one child per line, each indented one step past +level+, `]`
      # back at +level+ — so the closing bracket lines up under the call that opened
      # it, however deep this node sits in the tree.
      def children_source(children, level)
        pad = INDENT * (level + 1)
        lines = children.map { |child| "#{pad}#{source(child, level: level + 1)}," }
        "children: [\n#{lines.join("\n")}\n#{INDENT * level}]"
      end

      # An operand's value: a nested node (recurse), a list (an Array — recurse over
      # its elements, which may themselves be nodes, numbers, or further nested
      # arrays — a table's numbers, a case's [value, target] pairs), a record (a song's
      # part, a saved variable), or an author-time literal. Ruby's own #inspect already
      # writes an Integer/Symbol/String/bool back as valid source for anything else —
      # that is the whole reason the operand tags in {Verifier::TYPES} are plain Ruby
      # types and not a bespoke format.
      def value_source(value, level)
        case value
        when Node then source(value, level: level)
        when Array then "[#{value.map { |element| value_source(element, level) }.join(', ')}]"
        when String then string_source(value)
        when Data then record_source(value)
        when Graphics::Font then font_source(value)
        else value.inspect
        end
      end

      # A RECORD AN OPERAND CARRIES, written back as the call that builds one. A record
      # inspects as `#<data ...>`, which DESCRIBES it rather than rebuilding it, so the
      # fields are written out as keyword arguments instead.
      #
      # Only the ones the author actually set: a record that publishes a DEFAULTS table
      # has the fields still at their defaults left out, so a song part that sets nothing
      # but its notes reads that way in the dump too. One with no such table writes out
      # everything, which is right — nothing there is implied.
      def record_source(record)
        defaults = record.class.const_defined?(:DEFAULTS) ? record.class::DEFAULTS : {}
        said = record.to_h.reject { |field, value| defaults[field] == value }
        args = said.map { |field, value| "#{field}: #{value_source(value, 0)}" }
        "#{record.class.name}.new(#{args.join(', ')})"
      end

      # WHAT #record_source LEAVES OUT, for a key that must change with what a tree means: the
      # DEFAULTS of every record class +node+'s tree holds, one class a line, sorted by name. The
      # dump alone keys how a tree is written, and a field at its default is not written, so a
      # change to a class's DEFAULTS can change what the tree means and leave its dump as it was.
      def record_defaults_source(node)
        classes = record_classes_in(node, Set.new)
        classes.sort_by(&:name).map { |record_class| "#{record_class.name} #{record_class::DEFAULTS.inspect}\n" }.join
      end

      # Every record class with a DEFAULTS table that +value+ holds, however deep, added to +found+.
      def record_classes_in(value, found)
        case value
        when Node
          value.attrs.each_value { |operand| record_classes_in(operand, found) }
          value.children.each { |child| record_classes_in(child, found) }
        when Array then value.each { |element| record_classes_in(element, found) }
        when Data
          found << value.class if value.class.const_defined?(:DEFAULTS)
          value.to_h.each_value { |field| record_classes_in(field, found) }
        end
        found
      end

      # #inspect alone loses a binary string's encoding — re-read as ordinary source,
      # the literal comes back tagged with the FILE's encoding, not the ASCII-8BIT a
      # sample or a packed asset was built with. Appending `.b` (the codebase's own
      # shorthand for that, e.g. in test/conformance_fixture.rb) restores it, so a
      # dumped `data`/`sample` round-trips byte-for-byte AND tag-for-tag.
      def string_source(value)
        value.encoding == Encoding::ASCII_8BIT ? "#{binary_inspect(value)}.b" : value.inspect
      end

      # What #inspect gives for a binary +value+. A game whose data pack is left out holds its
      # pictures and recordings as zeros until the pack fills them, tens of millions of bytes, and
      # inspecting those one byte at a time took seconds; a String of zeros alone is written out
      # whole, as the same text.
      def binary_inspect(value)
        return value.inspect unless value.bytesize > ZEROS_WRITTEN_WHOLE && value.count("\x00") == value.bytesize

        "\"#{'\\x00' * value.bytesize}\""
      end

      # The size past which a String of zeros is written out whole, rather than inspected.
      ZEROS_WRITTEN_WHOLE = 256

      # A complete, standalone Ruby file: +program+ (a :program-kind node) wrapped in
      # a class named +class_name+ that can rebuild the tree and lower it to machine
      # code (VBlank::IR::Backends::GBA) — nothing more. No ROM header, no checksum,
      # no file written; that is `vblank build`'s job, not this file's. Run directly
      # (`ruby` it), it lowers once and stops, so it is a plain way to reproduce
      # exactly what a build's codegen produced, e.g. to bisect a compiler change.
      #
      # Everything a build needs is in +program+, fonts included: a font the game declared
      # rides on the program, so it comes back out with the tree. It used to be handed over
      # separately, because a font lived in a table shared by the whole process rather than
      # in the game that wrote it. The two fonts the framework ships need nothing here —
      # requiring the library brings those.
      def class_source(program, class_name:, fast_cartridge:, fast_code:, stack_room: nil)
        body = source(program, level: 2)
        <<~RUBY
          # frozen_string_literal: true

          # The IR VBlank::IR::Backends::GBA would lower for this game — a snapshot, not
          # a live view: editing the game file does not change this file. Generated by
          # `vblank build --format=ir`. Reconstructs the intermediate representation and
          # lowers it to machine code; nothing more — no ROM header, no checksum, no file
          # written. Run it directly to reproduce that codegen, e.g. to bisect a change to
          # the compiler.

          require "vblank"

          class #{class_name}
            def program
              #{body}
            end

            def lower
              VBlank::IR::Backends::GBA.new(fast_cartridge: #{fast_cartridge.inspect},
                                             fast_code: #{fast_code.inspect},
                                             stack_room: #{stack_room.inspect}).lower(program)
            end
          end

          #{class_name}.new.lower if $PROGRAM_NAME == __FILE__
        RUBY
      end

      def font_source(font)
        args = font.to_definition.map { |key, value| "#{key}: #{value.inspect}" }
        "VBlank::Graphics::Font.new(#{args.join(', ')})"
      end
    end
  end
end
