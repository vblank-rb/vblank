# frozen_string_literal: true

require "test_helper"
require "pose_color_list_tests"

# One sprite whose poses are drawn from different lists of colours, on every run that plays games as
# the Advance. Its build gives a whole sprite one group of sixteen colours, so such a sprite is
# refused in words that name the console, by the interpreter and by every build of the game.
class TestPoseColorListsOnTheAdvance < Minitest::Test
  include PoseColorListRefusedTests
end
