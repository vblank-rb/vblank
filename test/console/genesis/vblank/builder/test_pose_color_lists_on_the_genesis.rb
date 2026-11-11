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
end
