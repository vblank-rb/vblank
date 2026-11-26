# frozen_string_literal: true

require "test_helper"
require "pack_cells_in_front_tests"

# Cells of a background from the data pack drawn in front of the sprites (`cells_in_front: true`),
# on every run that plays games as the Game Boy Color. The Color keeps a priority bit for each cell, and its build sets it, so a sprite shows under a marked cell's drawn pixels. A sprite told `in_front: true` is refused in words, since a marked cell covers every sprite.
# The tests themselves are in test/pack_cells_in_front_tests.rb.
class TestPackCellsInFrontOnTheColor < Minitest::Test
  include PackCellsInFrontTests
  include PackSpriteInFrontRefusedTests
end
