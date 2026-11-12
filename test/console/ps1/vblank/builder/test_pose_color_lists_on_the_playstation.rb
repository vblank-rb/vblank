# frozen_string_literal: true

require "test_helper"
require "pose_color_list_tests"

# One sprite whose poses are drawn from different lists of colours, on every run that plays games as
# the PlayStation. A sprite there is a picture the graphics chip draws each frame, each with the
# table of colours the drawing names, so a pose is shown in its own list's colours and a sprite
# follows the lists its poses are drawn from.
class TestPoseColorListsOnThePlayStation < Minitest::Test
  include PoseColorListTests
  include PoseColorListFollowTests
end
