# frozen_string_literal: true

require "test_helper"
require "two_players_tests"

# Two people at a PlayStation, each on a pad of their own (TwoPlayersTests). The Super Nintendo's twin
# is test/console/snes/vblank/builder/test_two_players.rb.
class TestTwoPlayersOnThePlayStation < Minitest::Test
  include TwoPlayersTests
end
