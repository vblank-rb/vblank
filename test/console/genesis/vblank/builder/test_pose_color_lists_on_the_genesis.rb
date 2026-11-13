# frozen_string_literal: true

require "test_helper"
require "pose_color_list_tests"

# One sprite whose poses are drawn from different lists of colours, on every run that plays games as
# the Genesis. The video chip reads a piece's palette from the piece's own entry in the sprite
# table, so a pose is shown in its own list's colours, and a sprite follows the lists its poses are
# drawn from.
class TestPoseColorListsOnTheGenesis < Minitest::Test
  include PoseColorListTests
  include PoseColorListFollowTests
  include PoseColorListSwapTests

  # A sprite and a background following the same two lists, one of which the game never changes:
  # each shows every list's colours, the changed one's as it holds them now.
  def test_a_sprite_and_a_background_following_a_changed_and_an_unchanged_list_show_both
    program = followed_beside_background_game
    early = game_player.run(program, frames: 1 + framework_drawing_lag).screen

    assert_equal shown_all([WARM[2], WARM[1]]), [early.pixel(*LEFT_HALF), early.pixel(*RIGHT_HALF)], "the pose of :warm"
    assert_equal shown_all(WARM.drop(1) + COLD.drop(1)), [1, 5, 9, 13].map { |x| early.pixel(x, 1) }, "the background"

    late = game_player.run(program, frames: TURN_PASS + 2 + framework_drawing_lag).screen

    assert_equal shown_all(DUSK.drop(1)), [late.pixel(*LEFT_HALF), late.pixel(*RIGHT_HALF)], "the pose of :cold"
    assert_equal shown_all(WARM.drop(1) + DUSK.drop(1)), [1, 5, 9, 13].map { |x| late.pixel(x, 1) }, "the background"
  end
end
