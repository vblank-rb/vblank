# frozen_string_literal: true

require "test_helper"
require "pack_parity_tests"

# Every registered pack game, built with its pack left out, held to its all-in-one build, played
# on the interpreter (PackParityTests in test/pack_parity_tests.rb, which says why these are not in
# test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackParityInterpreter < Minitest::Test
  include PackParityTests
end
