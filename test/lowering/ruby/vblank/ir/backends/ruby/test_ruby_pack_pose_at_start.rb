# frozen_string_literal: true

require "test_helper"
require "pack_pose_at_start_tests"

# A POSE FROM THE PACK, ITS PACK LEFT OUT, played as Ruby and checked against the interpreter on
# every frame (PackPoseAtStartTests in test/pack_pose_at_start_tests.rb, which says why these are
# not in test/all/). The Ruby runtime reads the frame's pieces from the file it is handed, as the C
# runtime does.
class TestRubyPackPoseAtStart < Minitest::Test
  include PackPoseAtStartTests

  def test_the_pose_as_a_ruby_script_holds_none_of_the_originals_bytes
    assert_pose_written_without_the_originals_bytes do |program|
      VBlank::IR::Backends::Ruby.new.script(program, title: "Made Up")
    end
  end
end
