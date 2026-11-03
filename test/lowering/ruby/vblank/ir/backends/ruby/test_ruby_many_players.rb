# frozen_string_literal: true

require "test_helper"
require "many_players_games"

# MORE PLAYERS THAN EIGHT, played as Ruby and checked against the interpreter on every frame
# (Ruby::CheckedRun). The Ruby runtime keeps a list of buttons, one entry per connected player,
# rather than one number for everybody, so a game for a crowd plays the same as on the
# interpreter.
class TestRubyManyPlayers < Minitest::Test
  include ManyPlayersGames

  CheckedRun = VBlank::IR::Backends::Ruby::CheckedRun
  PLAYERS = 12

  def test_twelve_players_play_the_same_as_on_the_interpreter
    run = CheckedRun.new.input_each_frame { |frame| crowd_buttons_on(frame, PLAYERS) }.run(crowd(PLAYERS), frames: 24)

    assert_equal 2 * 12, run[:x12], "player twelve moved on frames 12 and 24"
    assert_equal PLAYERS, run[:connected]
    assert_operator run[:taps], :>, 0
  end

  def test_one_player_holding_reads_one_player_connected
    run = CheckedRun.new.hold(:right).run(crowd(PLAYERS), frames: 4)

    assert_equal 1, run[:connected]
    assert_equal 4, run[:x1]
  end
end
