# frozen_string_literal: true

require "test_helper"
require "pack_cells_in_front_tests"

# Cells of a background from the data pack drawn in front of the sprites (`cells_in_front: true`),
# on every run that plays games as the PlayStation. The PlayStation's build does not draw such a cell yet, so it refuses such a background in words.
# The tests themselves are in test/pack_cells_in_front_tests.rb.
class TestPackCellsInFrontOnThePlayStation < Minitest::Test
  include PackCellsInFrontRefusedTests
end
