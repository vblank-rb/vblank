# frozen_string_literal: true

require "test_helper"
require "frame_record_unpacking_tests"

# The frames a game names, written by its pack's unpacking, played as C and checked against the
# interpreter on every frame (FrameRecordUnpackingTests in test/frame_record_unpacking_tests.rb,
# which says why these are not in test/all/).
class TestNativeFrameRecordUnpacking < Minitest::Test
  include FrameRecordUnpackingTests
end
