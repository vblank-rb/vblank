# frozen_string_literal: true

require "test_helper"
require "pixelate_backgrounds_tests"

# The backgrounds in blocks and the sprites as drawn, on the Advance: the tests every console whose
# display can show it plays (PixelateBackgroundsTests in test/pixelate_backgrounds_tests.rb). The
# Super Nintendo's twin is test/console/snes/vblank/builder/test_pixelate_backgrounds_on_the_super_nintendo.rb.
class TestPixelateBackgroundsOnTheAdvance < Minitest::Test
  include PixelateBackgroundsTests
end
