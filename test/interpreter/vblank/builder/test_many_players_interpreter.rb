# frozen_string_literal: true

require "test_helper"
require "many_players_tests"

# MORE PLAYERS THAN A CONSOLE SEATS, played on the interpreter (ManyPlayersTests in
# test/many_players_tests.rb, which says why these are not in test/all/). The game as C, as
# JavaScript and as Ruby play the same tests.
class TestManyPlayersInterpreter < Minitest::Test
  include ManyPlayersTests
end
