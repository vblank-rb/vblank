# frozen_string_literal: true

require "test_helper"
require "pack_strip_font_at_start_tests"

# A FONT CUT FROM A STRIP OF THE PACK'S PICTURES, ITS PACK LEFT OUT, played as C and checked
# against the interpreter on every frame (PackStripFontAtStartTests in
# test/pack_strip_font_at_start_tests.rb, which says why these are not in test/all/).
class TestNativePackStripFontAtStart < Minitest::Test
  include PackStripFontAtStartTests
end
