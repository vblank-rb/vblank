# frozen_string_literal: true

require "test_helper"
require "many_players_tests"

# MORE PLAYERS THAN A CONSOLE SEATS, played as C and checked against the interpreter on every
# frame (ManyPlayersTests in test/many_players_tests.rb, which says why these are not in
# test/all/). The C runtime keeps a list of buttons, one number per connected player.
class TestNativeManyPlayers < Minitest::Test
  include ManyPlayersTests
end
