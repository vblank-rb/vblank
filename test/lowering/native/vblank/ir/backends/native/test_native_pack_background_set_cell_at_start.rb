# frozen_string_literal: true

require "test_helper"
require "pack_background_set_cell_at_start_tests"

# A cell of a background from the pack written with `set_cell`, its pack left out, played as C and
# checked against the interpreter on every frame (PackBackgroundSetCellAtStartTests in
# test/pack_background_set_cell_at_start_tests.rb, which says why these are not in test/all/). The
# C runtime fills a tile for each told cell from the file it is handed, beside the map's.
class TestNativePackBackgroundSetCellAtStart < Minitest::Test
  include PackBackgroundSetCellAtStartTests
end
