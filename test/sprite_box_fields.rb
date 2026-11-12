# frozen_string_literal: true

require "stringio"

# SMALL TILED GAMES FOR `ignoring_sprites:`, built for any console: a hollow 16 by 16 box sprite
# that steps one pixel right a frame from column 32 to 40 and back, over a field of sea, with one
# cell of rock where a test puts it; and the same sea with no sprite at all, the port whose
# characters are not made yet. The box covers the cell [5, 7] on every frame, and its middle shows
# the scenery through, so the rock there is in both pictures.
module SpriteBoxFields
  # A frame with nothing inside.
  HOLLOW_BOX = "#{'#' * 16}\n#{"##{'.' * 14}#\n" * 14}#{'#' * 16}\n".freeze

  # The cell the box covers on every frame, by column and row in cells.
  UNDER_THE_BOX = [5, 7].freeze

  # +columns+ and +rows+ are the map's size in cells, and +odd_cell+ the cell of rock, or nil for none.
  private def sea_with_box(console:, columns:, rows:, odd_cell: nil)
    map = Array.new(rows) { "." * columns }
    map[odd_cell[1]] = map[odd_cell[1]].dup.tap { |row| row[odd_cell[0]] = "x" } if odd_cell
    VBlank.build("FIELD", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white, "." => :transparent) { HOLLOW_BOX }
      image(:sea, "." => :blue) { "........\n" * 8 }
      image(:rock, "." => :red) { "........\n" * 8 }
      tiles :set, "." => :sea, "x" => :rock
      background :water, tiles: :set, map: map
      box = sprite :box, at: [32, 52]
      game_loop do
        box.x += 1
        box.x = 32 if box.x > 40
      end
    end
  end

  private def bare_sea(console:, columns:, rows:)
    VBlank.build("FIELD", console: console, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :water, tiles: :set, map: Array.new(rows) { "." * columns }
      game_loop {}
    end
  end
end
