# frozen_string_literal: true

require "test_helper"
require "pack_pose_at_start_tests"

# A POSE WHOSE FRAME IS THE CONSOLE'S OWN SPRITE ENTRIES, ITS PACK LEFT OUT, played as C and checked
# against the interpreter on every frame (PackPoseOfWordsAtStartTests in
# test/pack_pose_at_start_tests.rb).
class TestNativePackPoseOfWordsAtStart < Minitest::Test
  include PackPoseOfWordsAtStartTests
end
