# frozen_string_literal: true

require "test_helper"
require "palette_walk_tests"

# test/palette_walk_tests.rb on a Game Boy Color, whose runtime looks a colour's channels up in
# rt_tint_colors.
class TestGBCPaletteWalk < Minitest::Test
  include PaletteWalkTests

  CONSOLE = :gbc
  COLOR_ROUTINE = "rt_tint_colors"
end
