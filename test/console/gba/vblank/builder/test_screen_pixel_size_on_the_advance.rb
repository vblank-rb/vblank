# frozen_string_literal: true

require "test_helper"

# A PAINTED SCREEN WHOSE PIXELS ARE SHOWN TWICE AS BIG (`screen :bitmap, pixel_size: 2`): the game
# draws a 120×80 picture and the Advance shows each of its pixels as a square of four. The
# interpreter plays the small picture; the cartridge, the game as C, as JavaScript and as Ruby are
# each held to it. The Advance alone shows it this way, so these play on the runs that play games as
# the Advance; what the other consoles say is in test/all/vblank/builder/test_screen_pixel_size.rb.
class TestScreenPixelSizeOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  # A game on a screen of big pixels, +tear_free+ or not, that draws a frame round the edge of its
  # small screen, a block in the middle, a dot in its last corner and a word, and moves the block a
  # pixel each pass.
  private def game(tear_free: false)
    VBlank.game("BIGPIXELS", consoles: %i[gba]) do
      screen :bitmap, tear_free: tear_free, pixel_size: 2
      right = screen_width - 1
      bottom = screen_height - 1
      x = var :x, 10
      game_loop do
        clear_screen :blue
        fill_rect 0, 0, screen_width, 2, :white
        fill_rect 0, bottom - 1, screen_width, 2, :white
        pixel right, bottom, :red
        draw_rect_at x, 30, 20, 10, :yellow
        draw_text "HI", 4, 8, :green
        x += 1
        x = 10 if x > 90
      end
    end
  end

  def test_the_game_is_laid_out_on_a_screen_half_as_wide_and_half_as_tall
    widths = []
    VBlank.game("BIGPIXELS", consoles: %i[gba]) do
      screen :bitmap, pixel_size: 2
      widths << screen_width << screen_height
    end.program

    assert_equal [120, 80], widths
  end

  def test_the_interpreter_plays_the_small_picture
    screen = game_player.run(game.program, frames: 3).screen

    assert_equal [120, 80], [screen.width, screen.height]
    assert_equal shown(:red), screen.pixel(119, 79)
    assert_equal shown(:white), screen.pixel(60, 0)
  end

  def test_the_console_shows_the_small_picture_as_the_interpreter_does
    assert_backends_agree(game.program, frames: [3, 6], name: "BIGPIXELS")
  end

  def test_a_tear_free_screen_shows_the_small_picture_as_the_interpreter_does
    assert_backends_agree(game(tear_free: true).program, frames: [3, 6], name: "BIGPIXELST")
  end
end
