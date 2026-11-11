# frozen_string_literal: true

require "test_helper"
require "frame_record_unpacking_tests"

# THE FRAMES A GAME NAMES, WRITTEN BY ITS PACK'S UNPACKING, played as C and checked against the
# interpreter on every frame (FrameRecordUnpackingTests in test/frame_record_unpacking_tests.rb,
# which says why these are not in test/all/).
class TestNativeFrameRecordUnpacking < Minitest::Test
  include FrameRecordUnpackingTests
end
