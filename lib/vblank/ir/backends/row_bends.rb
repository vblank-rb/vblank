# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # What a game's row-by-row bends are, read off the program once for every lowering.
      #
      # `background.scroll_each_row { |row| ... }` gives each row of a background a sideways offset
      # of its own, worked out by the game's block once for every row of the screen in the gap
      # between frames (Reference#work_out_bends). Each console feeds those offsets to its display
      # its own way, a row at a time, but which bends there are, and what can be told about a block
      # before the game runs, is the program's and not the console's.
      #
      # Which bends: one for each background, the last `scroll_rows` written for it, wherever that
      # is, since a bend stands from power-on (Reference#collect_definitions). They come in the order
      # the backgrounds were first bent, which is the order their rows are worked out in. A bend
      # written for a name the program never declares as a background is never asked: there are no
      # rows of it to work out. Nor is one for a background on no screen, declared only in a
      # routine no run calls (Stacking.scenery_reached).
      #
      # Bands: a block that only works a number out, and reads its row only to compare it with a
      # number written in the game, gives one answer for whole bands of rows. A title arriving in two
      # halves, or a status line that stays put, says one thing about a great many rows, and the
      # answer can only change where the row crosses a number it is compared with. Asking the first
      # row of each band gives what asking every row would, which matters on a processor that
      # multiplies and divides a little at a time.
      #
      # That is true only of a block that does nothing but work a number out. Asked less often, a
      # block that counted something would count less, so anything that is not a plain sum, a read
      # of a table or a pick keeps being asked every row. The only variables it may write are the
      # hidden ones a pick keeps its number in, and it may not read another bend's row, which is
      # worked out in an order the bands do not keep.
      class RowBends
        # One background's bend: the background's name, the variable its row number is handed in,
        # the offset its block gives back, the statements the block runs first, and the
        # `scroll_rows` node it was read from.
        Bend = Data.define(:background, :row, :offset, :body, :node)

        # The statements a block in bands may run, the values it may work out, and the comparisons
        # of its row that mark where a band starts.
        BAND_STATEMENTS = %i[if else set].freeze
        BAND_VALUES = %i[int var_ref binop neg bit_not absolute clamped shift_right table_get data_byte].freeze
        BAND_COMPARES = %i[< <= > >= == !=].freeze

        attr_reader :bends

        def initialize(program)
          declared = Stacking.scenery_reached(program).to_set(&:name)
          last = {}
          program.walk.each { |node| last[node.name] = node if node.kind == :scroll_rows && declared.include?(node.name) }
          @bends = last.values.map { |node| Bend.new(background: node.name, row: node.row, offset: node.offset, body: node.children, node: node) }
          @rows = @bends.to_set(&:row)
        end

        def empty? = @bends.empty?

        # The `scroll_rows` nodes the bends were read from, for what reaches the routines and
        # statements a bend runs.
        def nodes = @bends.map(&:node)

        # The bend of the background named +name+, or nil.
        def bend_for(name) = @bends.find { |bend| bend.background == name }

        # The first row of each band of +bend+ on a screen +height+ rows tall, or nil where its block
        # has to be asked every row.
        def bands(bend, height)
          nodes = [*bend.body, bend.offset].flat_map { |part| part.walk.to_a }
          return nil unless nodes.all? { |node| plain_work?(node) }
          return nil if nodes.any? { |node| node.kind == :var_ref && node.name != bend.row && @rows.include?(node.name) }

          compared = nodes.select { |node| compares_row?(node, bend.row) }
          return nil unless nodes.count { |node| reads_row?(node, bend.row) } == compared.length

          [0, *compared.flat_map { |test| rows_it_turns_at(test, bend.row) }].uniq.select { |row| row.between?(0, height - 1) }.sort
        end

        # Whether the game can tell +bend+'s block ran while its background is not up: a block with
        # no statements changes nothing, unless it reads a list, whose index can stop the game.
        def observable_while_away?(bend)
          !bend.body.empty? || bend.offset.walk.any? { |node| node.kind == :list_get }
        end

        private

        def plain_work?(node)
          return false unless (node.value? ? BAND_VALUES : BAND_STATEMENTS).include?(node.kind)

          node.kind != :set || node.var.start_with?(Build::KEPT_VARIABLE_PREFIX)
        end

        def reads_row?(node, row) = node.kind == :var_ref && node.name == row

        # A comparison of the row with a number written in the game.
        def compares_row?(node, row)
          return false unless node.kind == :binop && BAND_COMPARES.include?(node.op)

          (reads_row?(node.lhs, row) && node.rhs.kind == :int) || (reads_row?(node.rhs, row) && node.lhs.kind == :int)
        end

        # The rows where +test+ gives another answer than on the row before: the number itself, or
        # the row after where the number still answers as the rows before it do.
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
