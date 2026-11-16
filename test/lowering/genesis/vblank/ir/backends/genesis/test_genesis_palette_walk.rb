# frozen_string_literal: true

require "test_helper"
require "palette_walk_tests"

# test/palette_walk_tests.rb on a Genesis, whose runtime works its colours out from the tables rt_tint_tables makes.
class TestGenesisPaletteWalk < Minitest::Test
  include PaletteWalkTests

  CONSOLE = :genesis
  COLOR_ROUTINE = "rt_tint_tables"
end
