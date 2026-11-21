# frozen_string_literal: true

module VBlank
  module DSL
    # A board of cells
    #
    # A board of equal-sized cells you paint one at a time: a game field measured in cells, not
    # pixels. Builder#grid hands one back. From then on the game names cells by column and row
    # (0, 1, 2 and on) and never multiplies by the cell size.
    #
    # ```ruby
    # board = grid :board, cols: 30, rows: 20, cell: 8, over: :black
    # board.set_cell   head_x, head_y, :white   # paint one cell
    # board.set_cell   old_x,  old_y,  :green   # the old head becomes a body cell
    # board.clear_cell tail_x, tail_y           # an empty cell goes back to the `over` colour
    # ```
    #
    # Painting a single cell, rather than clearing and drawing the whole board again every frame,
    # keeps the picture from tearing once the board fills up: only a few cells change each step,
    # and a few always fit in the short time the display gives you to draw in.
    #
    # The `over:` colour is the one a cleared cell shows. A grid is a flat field, so Grid#clear_cell
    # fills the cell with it. A thing that moves over scenery is a Sprite instead, which puts back
    # the pixels it covers.
    class Grid
      Build = IR::Build # :nodoc:

      # @param builder [Builder] the build these cell paints record into
      # @param name [Symbol] the board's name (for messages)
      # @param cols [Integer] columns across
      # @param rows [Integer] rows down
      # @param cell [Integer] a cell's size in pixels (even, so the fast fill is legal)
      # @param over [Symbol, String, Integer] the background color a cleared cell shows
      def initialize(builder, name:, cols:, rows:, cell:, over:)
        @builder = builder
        @name = name
        @cols = whole_positive!(cols, :cols)
        @rows = whole_positive!(rows, :rows)
        @cell = even_cell!(cell)
        @over = over
        fits_on_screen!
      end

      # The board's name, its columns across and rows down, and a cell's size in pixels, as the
      # game gave them to Builder#grid.
      attr_reader :name, :cols, :rows, :cell

      # Paints one cell in a colour.
      #
      # The column and row count in cells, from 0 at the top left. Each may be a number or a
      # variable the game works out, such as a moving piece's place. A number off the board is
      # refused when the game is built.
      #
      # ```ruby
      # board.set_cell 3, 4, :white
      # board.set_cell head_x, head_y, :yellow
      # ```
      def set_cell(col, row, color)
        paint(col, row, color)
      end

      # Paints one cell in the board's `over` colour, so it shows as empty again.
      #
      # ```ruby
      # board.clear_cell tail_x, tail_y
      # ```
      def clear_cell(col, row)
        paint(col, row, @over)
      end

      private

      # Fill the one cell at (col, row) with a color, in cell coordinates. It lowers
      # to a run-time-positioned rectangle the size of a cell — the same primitive a
      # hand-written `draw_rect_at col * cell, row * cell, cell, cell` would build, so
      # a grid inherits its clipping, cost, and guardrails for free.
      def paint(col, row, color)
        in_range!(col, :col, @cols)
        in_range!(row, :row, @rows)
        @builder.draw_rect_at(pixel(col), pixel(row), @cell, @cell, color)
      end

      # A cell coordinate as a pixel position. A constant folds to a plain number; a
      # run-time coordinate becomes `coord * cell`, multiplied on the console.
      def pixel(coord)
        fixed = Value.fixed_number(coord)
        return fixed * @cell if fixed

        Build.binop(:*, Value.node_for(coord), Build.int(@cell))
      end

      # Only a coordinate the author fixed can be range-checked as the program is
      # written; one the game works out is trusted (and clips at the screen edge if it
      # strays, like any other draw). Catching the common typo — a constant off the
      # board — here turns a silent bad write into a plain-language error.
      def in_range!(coord, axis, count)
        fixed = Value.fixed_number(coord)
        return if fixed.nil? || (0...count).cover?(fixed)

        raise ArgumentError,
              "#{axis} #{fixed} is off the #{@name.inspect} grid — valid #{axis}s are 0..#{count - 1}"
      end

      def whole_positive!(value, field)
        return value if Whole.positive?(value)

        raise ArgumentError, "grid :#{@name} needs a positive #{field}, got #{Messages::PlainWords.words_for_given(value)}"
      end

      # The board has to fit on the screen — a board wider or taller than the display
      # would put its far cells off the edge, where they'd silently never show (the
      # black-screen footgun). Catch it here, in plain terms, as the board is built.
      def fits_on_screen!
        width, height = @builder.console.screen_size
        overrun!("wide", @cols, @cell, @cols * @cell, width) if @cols * @cell > width
        overrun!("tall", @rows, @cell, @rows * @cell, height) if @rows * @cell > height
      end

      def overrun!(axis, count, cell, extent, screen)
        raise ArgumentError,
              "The grid :#{@name} is #{count} cells x #{cell}px = #{extent}px #{axis}. But the screen is " \
              "only #{screen}px #{axis}. So the far cells fall off the edge and never show. To fix this, " \
              "use fewer cells or a smaller cell size, so the board fits."
      end

      # A cell must be an even number of pixels: the fast rectangle fill writes two
      # pixels at a time, so an odd width can't be filled that way.
      def even_cell!(cell)
        unless Whole.positive?(cell)
          raise ArgumentError, "grid :#{@name} needs a positive cell size, got #{Messages::PlainWords.words_for_given(cell)}"
        end
        return cell if cell.even?

        raise ArgumentError, "grid :#{@name} cell size must be even (got #{cell}) so a cell can fast-fill"
      end
    end
  end
end
