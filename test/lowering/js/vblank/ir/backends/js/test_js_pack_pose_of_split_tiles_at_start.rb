# frozen_string_literal: true

require "test_helper"
require "pack_pose_of_split_tiles_at_start_tests"

# A POSE WHOSE TILE NUMBERS ARE KEPT IN TWO PLACES, ITS PACK LEFT OUT, played as JavaScript and
# checked against the interpreter on every frame (PackPoseOfSplitTilesAtStartTests in
# test/pack_pose_of_split_tiles_at_start_tests.rb, which says why these are not in test/all/).
class TestJSPackPoseOfSplitTilesAtStart < Minitest::Test
  include PackPoseOfSplitTilesAtStartTests
end
