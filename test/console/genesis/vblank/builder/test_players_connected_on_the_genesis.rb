# frozen_string_literal: true

require "test_helper"
require "players_connected_tests"

# HOW MANY PLAYERS ARE CONNECTED, on the Genesis, whose build reads its first pad only
# (PlayersConnectedTests in test/players_connected_tests.rb). The Advance's twin is
# test/console/gba/vblank/builder/test_players_connected.rb.
class TestPlayersConnectedOnTheGenesis < Minitest::Test
  include PlayersConnectedTests
end
