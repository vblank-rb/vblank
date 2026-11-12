# frozen_string_literal: true

require "test_helper"
require "pixelate_backgrounds_tests"

# THE BACKGROUNDS IN BLOCKS AND THE SPRITES AS DRAWN, on the Super Nintendo, whose mosaic reaches
# the backgrounds and never the sprites: the tests every console whose display can show it plays
# (PixelateBackgroundsTests in test/pixelate_backgrounds_tests.rb). The Advance's twin is
# test/console/gba/vblank/builder/test_pixelate_backgrounds_on_the_advance.rb.
class TestPixelateBackgroundsOnTheSuperNintendo < Minitest::Test
  include PixelateBackgroundsTests
end
