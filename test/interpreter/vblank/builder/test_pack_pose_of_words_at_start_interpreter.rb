# frozen_string_literal: true

require "test_helper"
require "pack_pose_at_start_tests"

# A POSE WHOSE FRAME IS THE CONSOLE'S OWN SPRITE ENTRIES, ITS PACK LEFT OUT, played on the
# interpreter (PackPoseOfWordsAtStartTests in test/pack_pose_at_start_tests.rb). The game as C, as
# JavaScript and as Ruby play the same tests.
class TestPackPoseOfWordsAtStartInterpreter < Minitest::Test
  include PackPoseOfWordsAtStartTests
end
