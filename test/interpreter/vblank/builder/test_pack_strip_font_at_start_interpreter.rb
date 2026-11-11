# frozen_string_literal: true

require "test_helper"
require "pack_strip_font_at_start_tests"

# A FONT CUT FROM A STRIP OF THE PACK'S PICTURES, ITS PACK LEFT OUT, played on the interpreter
# (PackStripFontAtStartTests in test/pack_strip_font_at_start_tests.rb, which says why these are
# not in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackStripFontAtStartInterpreter < Minitest::Test
  include PackStripFontAtStartTests
end
