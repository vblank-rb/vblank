# frozen_string_literal: true

require "test_helper"
require "pixelate_above_row_tests"

# THE BACKGROUNDS IN BLOCKS AND THE SPRITES AS DRAWN, on the Super Nintendo, whose mosaic reaches
# the backgrounds and never the sprites: the tests every console whose display can show it plays
# (PixelateBackgroundsTests in test/pixelate_backgrounds_tests.rb). The Advance's twin is
# test/console/gba/vblank/builder/test_pixelate_backgrounds_on_the_advance.rb.
#
# With them, the tests of a background held above a row (`above_row:`), which the Super Nintendo and
# DOS hold (PixelateAboveRowTests in test/pixelate_above_row_tests.rb).
class TestPixelateBackgroundsOnTheSuperNintendo < Minitest::Test
  include PixelateAboveRowTests
end
