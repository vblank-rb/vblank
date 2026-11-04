# frozen_string_literal: true

require "test_helper"
require "many_players_tests"

# MORE PLAYERS THAN A CONSOLE SEATS, played as JavaScript and checked against the interpreter on
# every frame (ManyPlayersTests in test/many_players_tests.rb, which says why these are not in
# test/all/). The browser's runtime keeps a list of buttons, one number per connected player, as
# the C and Ruby runtimes do.
class TestJSManyPlayers < Minitest::Test
  include ManyPlayersTests

  # Only a game for several players carries the session of a match and the relay's room, and its fingerprint.
  def test_a_game_for_one_player_carries_nothing_a_match_needs
    built = ->(players) { VBlank::IR::Backends::JS.new.factory(game_for(players)) }

    refute_match(/class RgLockstep|class RgRelayTransport|RG_FINGERPRINT|rg_game_mix_seed/, built.call(nil))
    refute_match(/class RgLockstep/, built.call(1..1))
    assert_match(/class RgLockstep/, built.call(1..2))
    assert_match(/RG_FINGERPRINT/, built.call(1..2))
  end

  private def game_for(players)
    options = players ? { players: players } : {}
    VBlank.game("ALONE", consoles: %i[gba], **options) { game_loop { pixel 2, 2, :red } }.checked_program(err: nil, console: :gba)
  end
end
