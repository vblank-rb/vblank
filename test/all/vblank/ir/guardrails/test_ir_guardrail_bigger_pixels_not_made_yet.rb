# frozen_string_literal: true

require "test_helper"

# What a game of big pixels (`screen :bitmap, pixel_size: 2`) cannot have yet is refused by name
# (Guardrails::Checks::BiggerPixelsNotMadeYet), on every console, and the same game without big
# pixels is told nothing.
class TestIrGuardrailBiggerPixelsNotMadeYet < Minitest::Test
  Check = VBlank::IR::Guardrails::Checks::BiggerPixelsNotMadeYet

  private def findings(&block) = Check.new.detect(VBlank.game("BIGPIXELS", consoles: %i[gba], &block).program)

  def test_a_camera_is_refused_with_big_pixels
    found = findings do
      screen :bitmap, pixel_size: 2
      game_loop do
        clear_screen :blue
        shake_screen intensity: 2, frames: 4 if pressed(:a)
      end
    end

    assert_equal [:bigger_pixels_not_made_yet], found.map(&:check).uniq
    assert_match(/shake_screen/, found.first.message)
    assert_equal :error, found.first.severity
  end

  def test_pixelate_is_refused_with_big_pixels_where_the_console_does_not_count_the_blocks_in_the_games_pixels
    program = VBlank.game("BIGBLOCKS", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      game_loop { pixelate 4 }
    end.program(console: :snes)

    assert_match(/pixelate/, Check.new.detect(program).first.message)
  end

  def test_pixelate_is_not_refused_on_the_advance
    found = findings do
      screen :bitmap, pixel_size: 2
      game_loop { pixelate 4 }
    end

    assert_empty found
  end

  def test_a_fade_held_to_a_rectangle_is_refused_where_the_console_does_not_double_it
    program = VBlank.game("BIGFADE", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      game_loop { fade :black, 50, inside: [0, 0, 20, 20] }
    end.program(console: :snes)

    assert_match(/fade held to a rectangle/, Check.new.detect(program).first.message)
  end

  def test_a_fade_held_to_a_rectangle_is_not_refused_on_the_advance
    found = findings do
      screen :bitmap, pixel_size: 2
      game_loop { fade :black, 50, inside: [0, 0, 20, 20] }
    end

    assert_empty found
  end

  def test_a_game_without_big_pixels_is_told_nothing
    found = findings do
      screen :bitmap
      game_loop do
        pixelate 4
        shake_screen intensity: 2, frames: 4 if pressed(:a)
      end
    end

    assert_empty found
  end
end
