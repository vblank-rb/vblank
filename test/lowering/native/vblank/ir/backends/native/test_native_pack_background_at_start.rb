# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND FROM THE PACK, ITS PACK LEFT OUT, played as C and checked against the interpreter on
# every frame (PackBackgroundAtStartTests in test/pack_background_tests.rb, which says why these
# are not in test/all/). The C runtime reads the map from the file it is handed and fills a tile
# for each cell before the game's first statement.
class TestNativePackBackgroundAtStart < Minitest::Test
  include PackBackgroundAtStartTests

  # The game as C holds its tiles' pixels and its map built all-in-one, and neither built with its
  # pack left out.
  def test_the_background_as_c_holds_none_of_the_originals_bytes
    assert_background_written_without_the_originals_bytes { |program| VBlank::IR::Backends::Native.new.lower(program) }
  end
end
