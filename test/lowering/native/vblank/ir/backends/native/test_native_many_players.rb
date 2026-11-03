# frozen_string_literal: true

require "test_helper"
require "many_players_games"

# MORE THAN TWO PLAYERS, played as C and checked against the interpreter on every frame
# (Native::CheckedRun). The C runtime keeps a list of buttons, one number per connected player, as
# the Ruby runtime does, so a game for a crowd plays the same as on the interpreter, up to the
# sixteen players any build reads (IR::Buttons::MOST_PLAYERS). The browser build still reads two,
# so these games are not in test/all/.
class TestNativeManyPlayers < Minitest::Test
  include ManyPlayersGames

  CheckedRun = VBlank::IR::Backends::Native::CheckedRun

  # Players join one after another and press on different frames, so a player's buttons read as
  # another's shows as a frame the two runs disagree on.
  private def four_players_on(frame)
    { 1 => %i[right], 2 => %i[p2_right], 3 => %i[p3_right p2_left], 4 => %i[p4_right], 5 => %i[p3_left p4_left],
      6 => %i[p4_right p2_right], 7 => [] }.fetch(frame, [])
  end

  def test_four_players_play_the_same_as_on_the_interpreter
    run = CheckedRun.new.input_each_frame { |frame| four_players_on(frame) }.run(four_markers, frames: 8)

    assert_equal [11, 12, 11, 12], (1..4).map { |player| run[:"x#{player}"] }
    assert_equal 4, run[:connected]
    assert_equal 2, run[:anyone_left]
  end

  def test_a_player_stays_connected_after_letting_go
    run = CheckedRun.new.input_each_frame { |frame| frame == 2 ? [:p3_a] : [] }.run(four_markers, frames: 5)

    assert_equal 3, run[:connected], "letting go is not unplugging"
  end

  def test_sixteen_players_play_the_same_as_on_the_interpreter
    players = VBlank::IR::Buttons::MOST_PLAYERS
    run = CheckedRun.new.input_each_frame { |frame| crowd_buttons_on(frame, players) }.run(crowd(players), frames: 32)

    assert_equal 16 * 2, run[:x16], "player sixteen moved on frames 16 and 32"
    assert_equal 9 * 3, run[:x9], "player nine moved on frames 9, 18 and 27"
    assert_equal players, run[:connected]
    assert_operator run[:anyone], :>, 0
    assert_operator run[:taps], :>, 0
  end

  def test_buttons_held_from_power_on_reach_the_third_player
    run = CheckedRun.new.hold(:p3_right).run(four_markers, frames: 4)

    assert_equal [10, 10, 14, 10], (1..4).map { |player| run[:"x#{player}"] }
    assert_equal 3, run[:connected]
  end
end
