# frozen_string_literal: true

module VBlank
  module IR
    # A VARIABLE KEPT A BYTE OR TWO WIDE (`var :x, 0, width: :byte`) holds what a list's slot of that
    # width holds: the low bits, read back with their sign, so 200 in a byte reads -56.
    #
    # Nothing in a backend knows that. Once a game is written, every statement that changes such a
    # variable is followed by a second one, `x = (x << 24) >> 24`, which is the wrap in the
    # arithmetic every backend already does. So the interpreter and each lowering agree with no
    # work of their own, and a game that names no width has nothing added.
    #
    # A console with a reason to may keep the variable in fewer bytes (the Color's processor works a
    # byte at a time, so four bytes is four times the work). Writing to those bytes is the wrap, and
    # it leaves out the second statement (#wrap?).
    module KeptWidths
      module_function

      # The bytes each width is kept in, and the numbers it holds.
      BYTES = Ractor.make_shareable({ byte: 1, half: 2 })

      def lowest(width) = -(1 << ((BYTES.fetch(width) * 8) - 1))
      def highest(width) = (1 << ((BYTES.fetch(width) * 8) - 1)) - 1

      # The variable +node+ changes, or nil for a statement that changes none.
      def written_by(node)
        case node.kind
        when :set, :add, :sub, :negate, :abs, :negate_abs, :clamp then node.var
        when :copy then node.dest
        end
      end

      # The bits of a number above +width+'s.
      def bits_above(width) = 32 - (BYTES.fetch(width) * 8)

      # The statement that wraps variable +name+ to +width+.
      def wrap(name, width)
        bits = Build.int(bits_above(width))
        Build.set(name, Build.binop(:>>, Build.binop(:<<, Build.var_ref(name), bits), Build.int(bits_above(width))))
      end

      # Is +node+ the wrap of the variable it writes to +width+?
      def wrap?(node, width)
        return false unless node.kind == :set

        down = node.value
        return false unless down.is_a?(Node) && down.kind == :binop && down.op == :>>

        up = down.lhs
        up.is_a?(Node) && up.kind == :binop && up.op == :<< && up.lhs.is_a?(Node) && up.lhs.kind == :var_ref &&
          up.lhs.name == node.var && [up.rhs, down.rhs].all? { |bits| written_number(bits) == bits_above(width) }
      end

      # The number +operand+ holds, if it was written in the program.
      def written_number(operand)
        return operand if operand.is_a?(Integer)

        operand.value if operand.is_a?(Node) && operand.kind == :int
      end

      # Every statement of +program+ that changes a variable in +widths+ ({name => width}) followed by
      # its wrap. +refuse+ is called with a variable, its width and a number written to it
      # that it cannot hold.
      def add_wraps(program, widths, &refuse)
        program.walk.to_a.each do |node|
          next unless node.children.any? { |child| widths.key?(written_by(child)) }

          followed = node.children.flat_map do |child|
            name = written_by(child)
            next [child] unless widths.key?(name)

            refuse_written_number(child, name, widths.fetch(name), &refuse)
            [child, wrap(name, widths.fetch(name)).tap { |wrapped| wrapped.parent = node }]
          end
          node.children.replace(followed)
        end
      end

      def refuse_written_number(node, name, width)
        number = node.kind == :set ? written_number(node.value) : nil
        yield name, width, number if number && !number.between?(lowest(width), highest(width))
      end
    end
  end
end
