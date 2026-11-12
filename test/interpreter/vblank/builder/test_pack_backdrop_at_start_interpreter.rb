# frozen_string_literal: true

require "test_helper"
require "pack_backdrop_at_start_tests"

# A SCREEN'S BACKDROP FROM THE PACK, ITS PACK LEFT OUT, played on the interpreter
# (PackBackdropAtStartTests in test/pack_backdrop_at_start_tests.rb, which says why these are not
# in test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackBackdropAtStartInterpreter < Minitest::Test
  include PackBackdropAtStartTests
end
