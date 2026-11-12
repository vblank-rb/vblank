# frozen_string_literal: true

require "test_helper"
require "pack_pose_of_split_tiles_at_start_tests"

# A POSE WHOSE TILE NUMBERS ARE KEPT IN TWO PLACES, ITS PACK LEFT OUT, played on the interpreter
# (PackPoseOfSplitTilesAtStartTests in test/pack_pose_of_split_tiles_at_start_tests.rb, which says
# why these are not in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackPoseOfSplitTilesAtStartInterpreter < Minitest::Test
  include PackPoseOfSplitTilesAtStartTests
end
