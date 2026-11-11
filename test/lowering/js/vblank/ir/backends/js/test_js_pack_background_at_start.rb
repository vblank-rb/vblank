# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND FROM THE PACK, ITS PACK LEFT OUT, played as JavaScript and checked against the
# interpreter on every frame (PackBackgroundAtStartTests in test/pack_background_tests.rb, which
# says why these are not in test/all/). The JavaScript runtime fills a tile for each cell of the
# map from the file it is handed, as the C runtime does.
class TestJSPackBackgroundAtStart < Minitest::Test
  include PackBackgroundAtStartTests

  def test_the_background_as_javascript_holds_none_of_the_originals_bytes
    assert_background_written_without_the_originals_bytes { |program| VBlank::IR::Backends::JS.new.lower(program) }
  end
end
