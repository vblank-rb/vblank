# frozen_string_literal: true

require "test_helper"
require "pack_pose_at_start_tests"

# A POSE FROM THE PACK, ITS PACK LEFT OUT, played as C and checked against the interpreter on every
# frame (PackPoseAtStartTests in test/pack_pose_at_start_tests.rb, which says why these are not in
# test/all/). The C runtime reads the frame's pieces from the file it is handed and paints the
# picture before the game's first statement.
class TestNativePackPoseAtStart < Minitest::Test
  include PackPoseAtStartTests

  # The game as C holds the pose's pixels built all-in-one, and none of them built with its pack
  # left out.
  def test_the_pose_as_c_holds_none_of_the_originals_bytes
    assert_pose_written_without_the_originals_bytes { |program| VBlank::IR::Backends::Native.new.lower(program) }
  end
end
