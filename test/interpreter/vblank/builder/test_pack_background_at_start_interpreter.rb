# frozen_string_literal: true

require "test_helper"
require "pack_background_tests"

# A BACKGROUND FROM THE PACK, ITS PACK LEFT OUT, played on the interpreter
# (PackBackgroundAtStartTests in test/pack_background_tests.rb, which says why these are not in
# test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackBackgroundAtStartInterpreter < Minitest::Test
  include PackBackgroundAtStartTests
end
