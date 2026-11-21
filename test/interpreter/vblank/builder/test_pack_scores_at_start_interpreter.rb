# frozen_string_literal: true

require "test_helper"
require "pack_scores_at_start_tests"

# Songs whose notes are in the pack, its pack left out, played on the interpreter
# (PackScoresAtStartTests in test/pack_scores_at_start_tests.rb, which says why these are not in
# test/all/). The game as C, as JavaScript and as Ruby play the same tests.
class TestPackScoresAtStartInterpreter < Minitest::Test
  include PackScoresAtStartTests
end
