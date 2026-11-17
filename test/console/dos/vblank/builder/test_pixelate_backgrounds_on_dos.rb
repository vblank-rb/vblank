# frozen_string_literal: true

require "test_helper"
require "pixelate_above_row_tests"

# THE BACKGROUNDS IN BLOCKS AND THE SPRITES AS DRAWN, on DOS, whose processor builds the view a background at
# a time and puts each one in blocks by itself before the next is laid over it: the tests every console whose
# display can show it plays (PixelateBackgroundsTests in test/pixelate_backgrounds_tests.rb), and those of a
# background held above a row (PixelateAboveRowTests in test/pixelate_above_row_tests.rb).
class TestPixelateBackgroundsOnDOS < Minitest::Test
  include PixelateAboveRowTests
end
