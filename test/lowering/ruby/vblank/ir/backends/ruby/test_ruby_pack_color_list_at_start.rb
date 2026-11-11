# frozen_string_literal: true

require "test_helper"
require "pack_color_list_at_start_tests"

# A LIST OF COLOURS FROM THE PACK, ITS PACK LEFT OUT, played as Ruby and checked against the
# interpreter on every frame (PackColorListAtStartTests in test/pack_color_list_at_start_tests.rb,
# which says why these are not in test/all/). The Ruby runtime reads the colours from the file it
# is handed, as the C runtime does.
class TestRubyPackColorListAtStart < Minitest::Test
  include PackColorListAtStartTests

  def test_the_lists_as_a_ruby_script_hold_none_of_the_originals_colors
    assert_lists_written_without_the_originals_colors do |program|
      VBlank::IR::Backends::Ruby.new.script(program, title: "Made Up")
    end
  end
end
