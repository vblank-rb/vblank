# frozen_string_literal: true

require "test_helper"
require "palette_walk_tests"

# test/palette_walk_tests.rb on a Super Nintendo, whose runtime works out what each channel becomes
# in rt_tint_table.
class TestSNESPaletteWalk < Minitest::Test
  include PaletteWalkTests

  CONSOLE = :snes
  COLOR_ROUTINE = "rt_tint_table"
end
