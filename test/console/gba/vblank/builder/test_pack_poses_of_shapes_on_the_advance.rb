# frozen_string_literal: true

require "test_helper"
require "pack_pose_of_shapes_games"

# A POSE READ FROM AN ADVANCE ORIGINAL WHOSE PIECES ARE EVERY SHAPE AND SIZE OF THE CONSOLE'S
# (PackPoseOfShapesGames). The answer key is the same pieces painted by hand, a tile at a time,
# their sizes taken from the console's table.
#
# The picture is 177 tiles, more sprites than a Game Boy Color shows at once, so this plays on
# the Advance's runs alone. The registry of pack games plays the same game on every run that
# leaves a pack out.
class TestPackPosesOfShapesOnTheAdvance < Minitest::Test
  include PackPoseOfShapesGames

  # THE SAME PIECES PAINTED BY HAND, one tile of 8x8 at a time. A piece that is mirrored shows its
  # last column first, each tile back to front; one that is upside down shows its last row first,
  # each tile's rows in reverse.
  private def pose_painted_by_hand
    painted = PIECES.flat_map do |piece|
      (0...piece.columns).to_a.product((0...piece.rows).to_a).map do |column, row|
        rows = VIDEO.fetch(ACROSS_ROWS.call(piece, column, row)).each_slice(8).to_a
        rows = rows.map(&:reverse) if piece.mirrored
        rows = rows.reverse if piece.upside_down
        shown_column = piece.mirrored ? piece.columns - 1 - column : column
        shown_row = piece.upside_down ? piece.rows - 1 - row : row
        [piece.left + (shown_column * 8), piece.top + (shown_row * 8), rows.flatten]
      end
    end
    game_showing_shapes_and_file { image :pose, pieces: painted, colors: :hero }.first
  end

  def test_a_frame_of_every_shape_and_size_draws_as_painted_by_hand
    Dir.mktmpdir do |folder|
      read = game_player.run(pose_of_shapes_and_file(original(folder)).first, frames: 4).screen
      painted = game_player.run(pose_painted_by_hand, frames: 4).screen

      assert_equal painted.to_a, read.to_a
      # The big square's last tile is at the picture's (56, 56), and the picture's top left at (80, 60).
      place = VIDEO.fetch(63).fetch(0)

      assert_equal COLORS.fetch(place), read.pixel(80 + 56, 60 + 56), "the big square's last tile"
    end
  end
end
