# frozen_string_literal: true

require "test_helper"
require "pack_background_set_cell_at_start_tests"

# A cell of a background from the pack written with `set_cell`, its pack left out, played as
# JavaScript and checked against the interpreter on every frame (PackBackgroundSetCellAtStartTests
# in test/pack_background_set_cell_at_start_tests.rb, which says why these are not in test/all/).
class TestJSPackBackgroundSetCellAtStart < Minitest::Test
  include PackBackgroundSetCellAtStartTests
end
