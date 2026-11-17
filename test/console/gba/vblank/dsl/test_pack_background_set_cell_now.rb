# frozen_string_literal: true

require "test_helper"
require "pack_cell_written_now_tests"

# The Advance writes every cell where the game asks already, so `now: true` changes nothing there.
class TestPackBackgroundSetCellNow < Minitest::Test
  include PackCellWrittenNowTests
end
