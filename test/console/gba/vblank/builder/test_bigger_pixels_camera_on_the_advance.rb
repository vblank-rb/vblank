# frozen_string_literal: true

require "test_helper"

# The camera in a game of big pixels (`screen :bitmap, pixel_size: 2`): `camera` and `shake_screen` are
# counted in the game's pixels, so the window over the small picture moves half a step of the console's
# for each, and what it shows past the picture's edge is the backdrop, as the interpreter shows it.
class TestBiggerPixelsCameraOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  private def game(&camera)
    VBlank.game("BIGCAM", consoles: %i[gba]) do
      screen :bitmap, pixel_size: 2
      step = var :step, 0
      game_loop do
        clear_screen :blue
        fill_rect 0, 0, screen_width, 2, :white
        fill_rect 20, 20, 30, 20, :yellow
        draw_text "HI", 4, 8, :green
        instance_exec(step, &camera)
        step += 1
        step = 0 if step > 40
      end
    end
  end

  def test_the_camera_moves_the_picture_as_the_interpreter_moves_it
    program = game { |step| camera step, step / 2 }.program

    assert_backends_agree(program, frames: [2, 5, 9], name: "BIGCAM")
  end

  def test_a_camera_moved_back_shows_the_backdrop_past_the_edge
    program = game { |step| camera 0 - step, 0 - (step / 2) }.program

    assert_backends_agree(program, frames: [2, 6, 12], name: "BIGCAMB")
  end

  def test_a_shaken_screen_is_shown_as_the_interpreter_shows_it
    program = game { |step| shake_screen intensity: 3, frames: 6 if step == 3 }.program

    assert_backends_agree(program, frames: [3, 5, 8], name: "BIGSHAKE")
  end
end
