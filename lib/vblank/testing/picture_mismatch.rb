# frozen_string_literal: true

module VBlank
  module Testing
    # TWO SCREENS THAT DISAGREE, as a failed picture check says it (Pictures#assert_backends_agree):
    # how many pixels differ, the first few with both colours, and WHERE, not just how many. The map
    # is the whole screen squashed to a grid of about 40 by 20, so a glance says "the sprite is in
    # the wrong place" or "the right edge is torn" or "everything below the map".
    #
    # +differences+ are [x, y, interpreter's colour, console's colour] rows; +frames+ and
    # +console_frames+ how far each side played; +width+ and +height+ the screen's. A test of the words
    # hands in made-up differences, which no real lowering would draw on purpose.
    class PictureMismatch < Data.define(:differences, :frames, :console_frames, :width, :height)
      # How many differences are listed one by one before the rest are counted.
      LISTED = 8

      def message
        cell_w, cell_h = cell
        lines = ["the backends drew different screens: #{differences.length} of #{width * height} pixels differ " \
                 "(interpreter ran #{frames} frames, console #{console_frames})"]
        lines << "  first differences (interpreter is the oracle — it says what the program means):"
        differences.first(LISTED).each do |x, y, want, got|
          lines << format("    (%3d,%3d)  interpreter %-10s  console %s", x, y, color_label(want), color_label(got))
        end
        lines << "  ...and #{differences.length - LISTED} more" if differences.length > LISTED
        lines << "  where they differ ( . = agree, # = differ; each cell is #{cell_w}x#{cell_h} pixels):"
        lines.concat(map_lines)
        lines.join("\n")
      end

      private

      # How many pixels across and down one cell of the map is: the screen in about 40 cells by 20, a
      # cell taking in the ragged last few when the screen does not divide evenly (a Game Boy Color's
      # 144 rows do not divide by 20).
      def cell = [width.fdiv(40).ceil, height.fdiv(20).ceil]

      # The screen boiled down to the grid: a cell is '#' if any pixel in it differs.
      def map_lines
        cell_w, cell_h = cell
        grid = Array.new(height.fdiv(cell_h).ceil) { Array.new(width.fdiv(cell_w).ceil, ".") }
        differences.each { |x, y, _, _| grid[y / cell_h][x / cell_w] = "#" }
        grid.map { |row| "    #{row.join}" }
      end

      # A readable name for a 15-bit colour, falling back to the raw value. 0 is the backdrop: what
      # shows where nothing was drawn.
      def color_label(value)
        return "backdrop" if value.zero?

        name = Graphics::Color::PRESETS.key(value)
        name ? name.to_s : format("0x%04X", value)
      end
    end
  end
end
