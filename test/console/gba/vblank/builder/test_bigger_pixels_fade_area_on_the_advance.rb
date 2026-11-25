# frozen_string_literal: true

require "test_helper"

# A fade held to a rectangle in a game of big pixels (`screen :bitmap, pixel_size: 2`): the rectangle
# is counted in the game's pixels, and the console doubles its edges for the display's window, so it
# darkens the same pixels the interpreter does.
class TestBiggerPixelsFadeAreaOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  private def game(&fade)
    VBlank.game("BIGFADE", consoles: %i[gba]) do
      screen :bitmap, pixel_size: 2
      game_loop do
        clear_screen :white
        fill_rect 0, 0, screen_width, 4, :red
        instance_exec(&fade)
      end
    end
  end

  def test_a_fade_held_inside_a_rectangle_darkens_the_same_pixels_as_the_interpreter
    program = game { fade :black, 75, inside: [10, 10, 40, 30] }.program

    assert_backends_agree(program, frames: [2, 5], name: "BIGFADEIN")
  end

  def test_a_fade_held_outside_a_rectangle_darkens_the_same_pixels_as_the_interpreter
    program = game { fade :black, 75, outside: [10, 10, 40, 30] }.program

    assert_backends_agree(program, frames: [2, 5], name: "BIGFADEOUT")
  end

  def test_the_rectangle_is_in_the_games_pixels
    screen = game_player.run(game { fade :black, 75, inside: [10, 10, 40, 30] }.program, frames: 3).screen

    refute_equal screen.pixel(20, 20), screen.pixel(5, 20), "inside the rectangle is darker than beside it"
    assert_equal screen.pixel(5, 20), screen.pixel(60, 20)
  end
end
