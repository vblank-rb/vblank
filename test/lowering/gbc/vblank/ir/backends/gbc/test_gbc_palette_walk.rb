# frozen_string_literal: true

require "test_helper"
require "palette_walk_tests"

# test/palette_walk_tests.rb on a Game Boy Color, whose runtime moves a colour's channels in
# rt_tint_channel.
class TestGBCPaletteWalk < Minitest::Test
  include PaletteWalkTests

  CONSOLE = :gbc
  COLOR_ROUTINE = "rt_tint_channel"
end
