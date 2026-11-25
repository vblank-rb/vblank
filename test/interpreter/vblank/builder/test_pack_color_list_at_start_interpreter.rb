# frozen_string_literal: true

require "test_helper"
require "pack_color_list_at_start_tests"

# A list of colours from the pack, its pack left out, played on the interpreter
# (PackColorListAtStartTests in test/pack_color_list_at_start_tests.rb, which says why these are
# not in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackColorListAtStartInterpreter < Minitest::Test
  include PackColorListAtStartTests
end
