# frozen_string_literal: true

require "test_helper"
require "pose_color_list_tests"

# One sprite whose poses are drawn from different lists of colours, on every run that plays games as
# the Super Nintendo. Each entry of the console's sprite table names one of eight palettes beside
# its tile, so a pose is shown in its own list's colours. The build does not make a sprite that
# follows those lists yet, and refuses one in words.
class TestPoseColorListsOnTheSuperNintendo < Minitest::Test
  include PoseColorListTests
  include PoseColorListFollowRefusedTests
end
