# frozen_string_literal: true

require "test_helper"
require "pack_background_set_cell_at_start_tests"

# A cell of a background from the pack written with `set_cell`, its pack left out, played on the
# interpreter (PackBackgroundSetCellAtStartTests in test/pack_background_set_cell_at_start_tests.rb,
# which says why these are not in test/all/). The game as C, as JavaScript and as Ruby play the
# same tests.
class TestPackBackgroundSetCellAtStartInterpreter < Minitest::Test
  include PackBackgroundSetCellAtStartTests
end
