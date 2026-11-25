# frozen_string_literal: true

require "test_helper"
require "pack_backdrop_at_start_tests"

# A screen's backdrop from the pack, its pack left out, played on the interpreter
# (PackBackdropAtStartTests in test/pack_backdrop_at_start_tests.rb, which says why these are not
# in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackBackdropAtStartInterpreter < Minitest::Test
  include PackBackdropAtStartTests
end
