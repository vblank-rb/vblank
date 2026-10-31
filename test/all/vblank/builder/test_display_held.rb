# frozen_string_literal: true

require "test_helper"

# A GAME THAT WAITS FOR FRAMES SHOWS NOTHING UNTIL ITS FIRST FRAME IS SET UP. Everything said before
# the game loop reaches the screen by work done between frames, so the display is switched off
# until then and shows plain white, the same on every lowering: a picture read before the first
# frame is white, and one read after it is the picture the game made.
class TestDisplayHeld < Minitest::Test
  WHITE = VBlank::Graphics::Color.resolve(:white)
  RED = VBlank::Graphics::Color.resolve(:red)

  private def red_screen_that_waits_for_frames
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      tiles :set, "#" => :red_art
      background :field, tiles: :set, map: Array.new(20) { "#" * 30 }
      game_loop {}
    end
    builder.finalize_program
    builder.program
  end

  def test_the_screen_is_white_before_the_first_frame_and_the_picture_after_it
    program = red_screen_that_waits_for_frames
    before, after = [0, 1].map { |frames| game_player.run(program, frames: frames).screen.pixel(10, 10) }

    assert_equal [WHITE, RED], [before, after]
  end
end
