# frozen_string_literal: true

require "test_helper"
require "pack_color_list_at_start_tests"

# A LIST OF COLOURS FROM THE PACK, ITS PACK LEFT OUT, played as C and checked against the
# interpreter on every frame (PackColorListAtStartTests in test/pack_color_list_at_start_tests.rb,
# which says why these are not in test/all/). The C runtime reads the colours from the file it is
# handed before the game's first statement, and puts them where the pictures name them.
class TestNativePackColorListAtStart < Minitest::Test
  include PackColorListAtStartTests

  def test_the_lists_as_c_hold_none_of_the_originals_colors
    assert_lists_written_without_the_originals_colors { |program| VBlank::IR::Backends::Native.new.lower(program) }
  end
end
