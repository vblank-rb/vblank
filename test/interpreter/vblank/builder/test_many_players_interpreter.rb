# frozen_string_literal: true

require "test_helper"
require "many_players_games"

# FOUR PEOPLE AT ONE GAME, played on the interpreter, which plays a program past every console's
# controllers: each moves a marker of their own, `:any` is every connected player, and the game
# can ask how many are connected. A test holds the third player's buttons as :p3_left. Which
# console seats how many is test/all/vblank/builder/test_player_option.rb's. The browser build
# reads two players, so this is not in test/all/; the game as C and as Ruby play the same games
# (test/many_players_games.rb).
class TestManyPlayersInterpreter < Minitest::Test
  include ManyPlayersGames

  private def played(*buttons) = VBlank::IR::Backends::Reference.new.hold(*buttons).run(four_markers, frames: 5)

  private def marker_at(run, player) = (0...240).find { |x| run.screen.pixel(x, MARKER_ROWS.fetch(player)) == Color.resolve(:red) }

  def test_each_of_four_players_moves_their_own_marker_on_the_same_pass
    run = played(:p2_right, :p4_right)

    assert_equal [10, 15, 10, 15], (1..4).map { |player| run[:"x#{player}"] }
    assert_equal [10, 15, 10, 15], (1..4).map { |player| marker_at(run, player) }
  end

  def test_the_third_players_buttons_are_theirs_alone
    run = played(:p3_right)

    assert_equal [10, 10, 15, 10], (1..4).map { |player| run[:"x#{player}"] }
  end

  def test_any_player_is_every_connected_player
    %i[left p2_left p3_left p4_left].each do |button|
      assert_equal 5, played(button)[:anyone_left], button.to_s
    end
    assert_equal 0, played(:p4_right)[:anyone_left]
  end

  def test_one_player_is_connected_while_a_test_holds_only_the_first_players_buttons
    assert_equal 1, played(:right)[:connected]
    assert_equal 1, played[:connected]
  end

  def test_a_player_counts_as_connected_from_their_first_button_on
    run = VBlank::IR::Backends::Reference.new
                                         .input_each_frame { |frame| frame == 2 ? [:p3_a] : [] }
                                         .run(four_markers, frames: 5)

    assert_equal 3, run[:connected], "letting go is not unplugging"
  end
end
