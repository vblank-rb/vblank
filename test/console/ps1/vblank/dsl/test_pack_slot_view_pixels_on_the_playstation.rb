# frozen_string_literal: true

require "test_helper"
require "pack_slot_view_pixel_tests"

# Pixels and tables read through views of a slot of tiles, on the PlayStation: the tests every
# console that shows the picture plays (PackSlotViewPixelTests in test/pack_slot_view_pixel_tests.rb).
class TestPackSlotViewPixelsOnThePlayStation < Minitest::Test
  include PackSlotViewPixelTests
end
