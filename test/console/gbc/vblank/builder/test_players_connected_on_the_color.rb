# frozen_string_literal: true

require "test_helper"
require "players_connected_tests"

# How many players are connected, on the Color: its one controller (PlayersConnectedTests in
# test/players_connected_tests.rb). The Advance's twin is
# test/console/gba/vblank/builder/test_players_connected.rb.
class TestPlayersConnectedOnTheColor < Minitest::Test
  include PlayersConnectedTests
end
