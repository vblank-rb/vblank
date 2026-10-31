# frozen_string_literal: true

require "test_helper"

# The two buttons only a Super Nintendo controller has. What every console's buttons do is
# test/all/vblank/builder/test_input.rb; these are the same words on the two it adds.
class TestInputOnTheSuperNintendo < Minitest::Test
  private def counting_game
    b = Builder.new
    b.instance_eval do
      held_x = 0
      pressed_y = 0
      any = 0
      game_loop do
        held_x += 1 if held(:x)
        pressed_y += 1 if pressed(:y)
        any += 1 if pressed(:any)
      end
    end
    b.finalize_program
    b.program
  end

  private def played(&buttons) = game_player.input_each_frame(&buttons).run(counting_game, frames: 10)

  def test_x_is_held_for_as_long_as_it_is_down
    run = played { |frame| frame.between?(2, 5) ? [:x] : [] }

    assert_equal 4, run[:held_x]
    assert_equal 0, run[:pressed_y]
  end

  def test_y_is_pressed_once_for_each_time_it_goes_down
    run = played { |frame| [2, 3, 6].include?(frame) ? [:y] : [] }

    assert_equal 2, run[:pressed_y]
    assert_equal 0, run[:held_x]
  end

  # A title that waits for any button counts these two as well.
  def test_x_and_y_are_each_any_button
    run = played { |frame| { 2 => [:x], 5 => [:y] }.fetch(frame, []) }

    assert_equal 2, run[:any]
  end
end
