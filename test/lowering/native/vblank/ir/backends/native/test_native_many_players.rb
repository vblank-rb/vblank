# frozen_string_literal: true

require "test_helper"
require "many_players_tests"

# MORE PLAYERS THAN A CONSOLE SEATS, played as C and checked against the interpreter on every
# frame (ManyPlayersTests in test/many_players_tests.rb, which says why these are not in
# test/all/). The C runtime keeps a list of buttons, one number per connected player.
class TestNativeManyPlayers < Minitest::Test
  include ManyPlayersTests

  # Only a game for several players is written with the routine a match adds its seed by.
  def test_a_game_for_one_player_is_written_without_a_match_seed_routine
    written = ->(players) { VBlank::IR::Backends::Native.new.lower(game_for(players)) }

    refute_match(/mix_seed/, written.call(nil))
    refute_match(/mix_seed/, written.call(1..1))
    assert_match(/mix_seed/, written.call(1..2))
  end

  private def game_for(players)
    options = players ? { players: players } : {}
    VBlank.game("ALONE", consoles: %i[gba], **options) { game_loop { pixel 2, 2, :red } }.checked_program(err: nil, console: :gba)
  end
end
