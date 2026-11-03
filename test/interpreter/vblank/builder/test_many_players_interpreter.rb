# frozen_string_literal: true

require "test_helper"

# FOUR PEOPLE AT ONE GAME, played on the interpreter, which plays a program past every console's
# controllers: each moves a marker of their own, `:any` is every connected player, and the game
# can ask how many are connected. A test holds the third player's buttons as :p3_left. Which
# console seats how many is test/all/vblank/builder/test_player_option.rb's.
class TestManyPlayersInterpreter < Minitest::Test
  ROWS = { 1 => 10, 2 => 30, 3 => 50, 4 => 70 }.freeze

  private def four_markers
    b = Builder.new
    b.instance_eval do
      x1 = 10
      x2 = 10
      x3 = 10
      x4 = 10
      anyone_left = 0
      connected = 0
      game_loop do
        x1 += 1 if held(:right, player: 1)
        x2 += 1 if held(:right, player: 2)
        x3 += 1 if held(:right, player: 3)
        x4 += 1 if held(:right, player: 4)
        anyone_left += 1 if held(:left, player: :any)
        connected = players_connected
        clear_screen :black
        draw_rect_at x1, 10, 2, 2, :red
        draw_rect_at x2, 30, 2, 2, :red
        draw_rect_at x3, 50, 2, 2, :red
        draw_rect_at x4, 70, 2, 2, :red
      end
    end
    b.finalize_program
    b.program
  end

  private def played(*buttons) = VBlank::IR::Backends::Reference.new.hold(*buttons).run(four_markers, frames: 5)

  private def marker_at(run, player) = (0...240).find { |x| run.screen.pixel(x, ROWS.fetch(player)) == Color.resolve(:red) }

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
