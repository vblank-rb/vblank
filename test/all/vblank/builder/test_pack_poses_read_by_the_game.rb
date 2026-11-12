# frozen_string_literal: true

require "test_helper"
require "pack_pose_read_by_the_game_games"

# POSES WHOSE FRAMES THE GAME READS WITH A FEW LINES OF ITS OWN (Original::FrameLayout's piece:),
# each given its object's block of sprite memory by the pose (PackPoseReadByTheGameGames). The
# answer key is the same pieces painted by hand, their tiles taken from the original's table of
# where each block starts. The registry of pack games plays the same game with the pack left out.
class TestPackPosesReadByTheGame < Minitest::Test
  include PackPoseReadByTheGameGames

  # THE SAME PIECES PAINTED BY HAND for an object in block +block+, one tile of 8x8 at a time. A
  # big piece is four tiles: its first, the next, and the two a row of sprite memory (16) on. A
  # mirrored piece shows its last column first, each tile back to front; one upside down shows its
  # last row first, each tile's rows in reverse. Public: the game block calls it back.
  def pieces_painted_by_hand(block)
    PIECES.flat_map do |piece|
      (0...piece.side).to_a.product((0...piece.side).to_a).map do |column, row|
        rows = VIDEO.fetch(piece.first_tile(block) + column + (row * 16)).each_slice(8).to_a
        rows = rows.map(&:reverse) if piece.mirrored
        rows = rows.reverse if piece.upside_down
        shown_column = piece.mirrored ? piece.side - 1 - column : column
        shown_row = piece.upside_down ? piece.side - 1 - row : row
        [ORIGIN[0] + piece.x + (shown_column * 8), ORIGIN[1] + piece.y + (shown_row * 8), rows.flatten]
      end
    end
  end

  private def poses_painted_by_hand
    test = self
    game_of_two_poses_and_file do
      image :craft, pieces: test.pieces_painted_by_hand(CRAFT_BLOCK), colors: :ink, size: REACH
      image :text, pieces: test.pieces_painted_by_hand(TEXT_BLOCK), colors: :ink, size: REACH
    end.first
  end

  def test_poses_of_one_frame_given_two_blocks_draw_as_painted_by_hand
    Dir.mktmpdir do |folder|
      read = game_player.run(poses_read_by_the_game_and_file(original(folder)).first, frames: 4).screen
      painted = game_player.run(poses_painted_by_hand, frames: 4).screen

      assert_equal painted.to_a, read.to_a
      # The craft's first piece is its block's first tile, ORed with 1, at the picture's top left.
      tile = BLOCK_STARTS.fetch(CRAFT_BLOCK) | 1

      assert_equal COLORS.fetch(VIDEO.fetch(tile).fetch(9)), read.pixel(CRAFT_AT[0] + 1, CRAFT_AT[1] + 1)
    end
  end

  def test_a_frame_given_a_value_its_reader_does_not_read_is_refused
    Dir.mktmpdir do |folder|
      from = original(folder)
      error = assert_raises(ArgumentError) do
        game_of_two_poses_and_file do
          pack = data_pack from: from, version: "1" do |slots|
            slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.length, width: :byte, signed: false
          end
          pack[:frames].frame(0, layout: FRAME, with: { blok: 5 })
        end
      end

      assert_includes error.message, ":block"
    end
  end
end
