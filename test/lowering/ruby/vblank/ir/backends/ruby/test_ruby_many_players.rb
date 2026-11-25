# frozen_string_literal: true

require "test_helper"
require "many_players_tests"

# More players than a console seats, played as Ruby and checked against the interpreter on every
# frame (ManyPlayersTests in test/many_players_tests.rb, which says why these are not in
# test/all/). The Ruby runtime keeps a list of buttons, one entry per connected player.
class TestRubyManyPlayers < Minitest::Test
  include ManyPlayersTests
end
