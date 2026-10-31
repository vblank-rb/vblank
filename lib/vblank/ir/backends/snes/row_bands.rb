# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        # WHERE A ROW-BY-ROW BEND CAN ONLY CHANGE, read off the bend alone.
        #
        # A bend's block is asked for all 224 rows every pass. Most of what a row costs there is
        # the 65816 multiplying and dividing a little at a time, so a block with a table read in it
        # is about a frame on its own, and a game counting in passes plays in slow motion. But a
        # title arriving in two halves, or a status line that stays put, says one thing about a
        # great many rows: the answer can only change where the row crosses a number it is
        # compared with. Asking the first row of each band gives what asking every row would.
        #
        # THAT IS TRUE ONLY OF A BLOCK THAT DOES NOTHING BUT WORK A NUMBER OUT. Asked less often,
        # a block that counted something would count less, so anything that is not a plain sum, a
        # read of a table or a pick keeps being asked every row. The only variables it may write
        # are the hidden ones a pick keeps its number in.
        module RowBands
          STATEMENTS = %i[if else set].freeze
          VALUES = %i[int var_ref binop neg bit_not absolute clamped shift_right table_get data_byte].freeze
          COMPARES = %i[< <= > >= == !=].freeze

          module_function

          # The first row of each band of +bend+ on a screen +height+ rows tall, or nil where its
          # block has to be asked every row.
          def firsts(bend, height)
            nodes = [*bend.children, bend.offset].flat_map { |part| part.walk.to_a }
            return nil unless nodes.all? { |node| plain_work?(node) }

            compared = nodes.select { |node| compares_row?(node, bend.row) }
            return nil unless nodes.count { |node| reads_row?(node, bend.row) } == compared.length

            [0, *compared.flat_map { |test| rows_it_turns_at(test, bend.row) }].uniq.select { |row| row.between?(0, height - 1) }.sort
          end

          def plain_work?(node)
            return false unless (node.value? ? VALUES : STATEMENTS).include?(node.kind)

            node.kind != :set || node.var.start_with?(Build::KEPT_VARIABLE_PREFIX)
          end

          def reads_row?(node, row) = node.kind == :var_ref && node.name == row

          # A comparison of the row with a number written in the game.
          def compares_row?(node, row)
            return false unless node.kind == :binop && COMPARES.include?(node.op)

            (reads_row?(node.lhs, row) && node.rhs.kind == :int) || (reads_row?(node.rhs, row) && node.lhs.kind == :int)
          end

          # The rows where +test+ gives another answer than on the row before: the number itself,
          # or the row after where the number still answers as the rows before it do.
          def rows_it_turns_at(test, row)
            row_first = reads_row?(test.lhs, row)
            number = row_first ? test.rhs.value : test.lhs.value
            case test.op
            when :==, :!= then [number, number + 1]
            when :<, :>= then row_first ? [number] : [number + 1]
            else row_first ? [number + 1] : [number]
            end
          end
        end
      end
    end
  end
end
