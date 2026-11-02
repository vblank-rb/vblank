# frozen_string_literal: true

require "test_helper"

# TWO PEOPLE AT ONE CONSOLE. Each reads their own controller, and a game can also ask whether a
# button is down on either. A test holds the second controller's buttons as :p2_left.
class TestTwoPlayers < Minitest::Test
  private def two_movers
    b = Builder.new
    b.instance_eval do
      first = 0
      second = 0
      either = 0
      joins = 0
      any_of_second = 0
      game_loop do
        first += 1 if held(:left)
        second += 1 if held(:left, player: 2)
        either += 1 if held(:left, player: :any)
        joins += 1 if pressed(:start, player: 2)
        any_of_second += 1 if pressed(:any, player: 2)
      end
    end
    b.finalize_program
    b.program
  end

  private def played(*buttons) = game_player.hold(*buttons).run(two_movers, frames: 5)
  private def played_with(&buttons) = game_player.input_each_frame(&buttons).run(two_movers, frames: 10)

  def test_each_controller_is_read_on_its_own
    first = played(:left)
    second = played(:p2_left)

    assert_operator first[:first], :>, 0
    assert_equal 0, first[:second]
    assert_equal 0, second[:first]
    assert_operator second[:second], :>, 0
  end

  def test_both_controllers_are_read_on_the_same_frame
    run = played(:left, :p2_left)

    assert_equal run[:first], run[:second]
    assert_equal run[:first], run[:either]
  end

  def test_a_button_on_either_controller_counts_for_any_player
    assert_operator played(:left)[:either], :>, 0
    assert_operator played(:p2_left)[:either], :>, 0
  end

  def test_a_press_on_the_second_controller_is_seen_once
    run = played_with { |frame| frame.between?(3, 6) ? [:p2_start] : [] }

    assert_equal 1, run[:joins]
    assert_equal 1, run[:any_of_second]
  end

  def test_the_first_controller_is_not_the_second_for_any_button
    run = played_with { |frame| frame.between?(3, 6) ? [:start] : [] }

    assert_equal 0, run[:joins]
    assert_equal 0, run[:any_of_second]
  end
end
