# frozen_string_literal: true

require "test_helper"
require "packing_gba_tests"

# The Game Boy Advance BIOS's formats in an unpacking routine built as Ruby (PackingGBATests).
class TestPackingGBAAsRuby < Minitest::Test
  include PackingGBATests
end
