# frozen_string_literal: true

require "test_helper"
require "players_connected_tests"

# How many players are connected, on the Advance: its one controller (PlayersConnectedTests in
# test/players_connected_tests.rb). The Color's twin is
# test/console/gbc/vblank/builder/test_players_connected_on_the_color.rb.
class TestPlayersConnected < Minitest::Test
  include PlayersConnectedTests
end
