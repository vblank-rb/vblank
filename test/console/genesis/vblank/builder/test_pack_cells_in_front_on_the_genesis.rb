# frozen_string_literal: true

require "test_helper"
require "pack_cells_in_front_tests"

# Cells of a background from the data pack drawn in front of the sprites (`cells_in_front: true`),
# on every run that plays games as the Sega Genesis. Its build sets the priority bit of each such cell in the plane's map, and the console draws it over the sprites.
# The tests themselves are in test/pack_cells_in_front_tests.rb.
class TestPackCellsInFrontOnTheGenesis < Minitest::Test
  include PackCellsInFrontTests
  include PackSpritesInFrontTests
end
