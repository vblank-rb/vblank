# frozen_string_literal: true

require "test_helper"
require "pack_slot_view_pixel_tests"

# PIXELS AND TABLES READ THROUGH VIEWS OF A SLOT OF TILES, on the Super Nintendo: the tests every
# console that shows the picture plays (PackSlotViewPixelTests in test/pack_slot_view_pixel_tests.rb).
class TestPackSlotViewPixelsOnTheSuperNintendo < Minitest::Test
  include PackSlotViewPixelTests
end
