# frozen_string_literal: true

require "test_helper"
require "pack_pose_at_start_tests"

# A pose from the pack, its pack left out, played on the interpreter (PackPoseAtStartTests in
# test/pack_pose_at_start_tests.rb, which says why these are not in test/all/). The game as C, as
# JavaScript and as Ruby play the same tests.
class TestPackPoseAtStartInterpreter < Minitest::Test
  include PackPoseAtStartTests
end
