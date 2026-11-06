# frozen_string_literal: true

require "test_helper"
require "pack_at_start_tests"

# A GAME HANDED ITS DATA PACK AS IT STARTS, played on the interpreter (PackAtStartTests in
# test/pack_at_start_tests.rb, which says why these are not in test/all/). The game as C, as
# JavaScript and as Ruby play the same tests.
class TestPackAtStartInterpreter < Minitest::Test
  include PackAtStartTests
end
