# frozen_string_literal: true

require "test_helper"
require "frame_record_unpacking_tests"

# The frames a game names, written by its pack's unpacking, played on the interpreter
# (FrameRecordUnpackingTests in test/frame_record_unpacking_tests.rb, which says why these are not
# in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestFrameRecordUnpackingInterpreter < Minitest::Test
  include FrameRecordUnpackingTests
end
