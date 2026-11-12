# frozen_string_literal: true

require "test_helper"
require "pack_parity_tests"

# EVERY REGISTERED PACK GAME, BUILT WITH ITS PACK LEFT OUT, HELD TO ITS ALL-IN-ONE BUILD, played
# on the interpreter (PackParityTests in test/pack_parity_tests.rb, which says why these are not in
# test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackParityInterpreter < Minitest::Test
  include PackParityTests
end
