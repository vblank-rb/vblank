# frozen_string_literal: true

require "test_helper"
require "pack_backdrop_at_start_tests"

# A SCREEN'S BACKDROP FROM THE PACK, ITS PACK LEFT OUT, played as JavaScript and checked against
# the interpreter on every frame (PackBackdropAtStartTests in test/pack_backdrop_at_start_tests.rb,
# which says why these are not in test/all/). The JavaScript runtime reads the colour from the file
# it is handed, as the C runtime does.
class TestJSPackBackdropAtStart < Minitest::Test
  include PackBackdropAtStartTests

  def test_the_backdrop_as_javascript_holds_none_of_the_originals_colors
    assert_backdrop_written_without_the_originals_color { |program| VBlank::IR::Backends::JS.new.lower(program) }
  end
end
