# frozen_string_literal: true

require "test_helper"
require "many_players_tests"

# MORE PLAYERS THAN A CONSOLE SEATS, played as JavaScript and checked against the interpreter on
# every frame (ManyPlayersTests in test/many_players_tests.rb, which says why these are not in
# test/all/). The browser's runtime keeps a list of buttons, one number per connected player, as
# the C and Ruby runtimes do.
class TestJSManyPlayers < Minitest::Test
  include ManyPlayersTests
end
