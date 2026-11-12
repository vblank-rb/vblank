# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND FROM THE PACK, ITS PACK LEFT OUT, played as Ruby and checked against the interpreter
# on every frame (PackBackgroundAtStartTests in test/pack_background_tests.rb, which says why these
# are not in test/all/). The Ruby runtime fills a tile for each cell of the map from the file it is
# handed, as the C runtime does.
class TestRubyPackBackgroundAtStart < Minitest::Test
  include PackBackgroundAtStartTests

  def test_the_background_as_a_ruby_script_holds_none_of_the_originals_bytes
    assert_background_written_without_the_originals_bytes do |program|
      VBlank::IR::Backends::Ruby.new.script(program, title: "Made Up")
    end
  end
end
