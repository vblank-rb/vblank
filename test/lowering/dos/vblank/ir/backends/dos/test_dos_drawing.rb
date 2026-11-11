# frozen_string_literal: true

require "test_helper"

# DRAWING ON THE VGA CARD, in DOSBox, held to the interpreter pixel for pixel on every pass (DOS::CheckedRun):
# what the first games of test_dos_checked_run.rb do not reach. A checked run that ends is a picture that
# agreed everywhere, so most of these assert only a pixel or two that show the test drew what it meant to.
class TestDOSDrawing < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  BARS = %i[red red green green blue blue white white].freeze

  private def checked(frames: 2, &game)
    DOS::CheckedRun.new.run(VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos), frames: frames)
  end

  # Every kind of drawing, each partly inside the area and partly outside it, on every side.
  def test_every_drawing_is_held_to_an_area
    run = checked do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      clear_screen :blue
      inside 40, 20, 120, 80 do
        clear_screen :black
        fill_rect 30, 10, 20, 20, :red
        fill_rect 150, 90, 40, 40, :green
        draw_rect_at 100, 0, 8, 200, :white
        pixel 39, 50, :yellow
        pixel 40, 50, :yellow
        pixel 159, 99, :yellow
        pixel 160, 100, :yellow
        blit :bars, 39, 19
        blit :bars, 159, 97
        draw_text "EDGE", 30, 60, :white
        draw_text "EDGE", 140, 95, :white
      end
      halt
    end

    assert_equal [VBlank::Graphics::Color.resolve(:blue), VBlank::Graphics::Color.resolve(:yellow)],
                 [run.screen.pixel(39, 50), run.screen.pixel(40, 50)]
  end

  # One area is in force at a time: the second is its own, and when each block ends drawing is held to
  # nothing but the screen again.
  def test_an_area_ends_with_its_block
    run = checked do
      screen :bitmap
      clear_screen :blue
      inside(100, 100, 20, 20) { fill_rect 0, 0, 320, 200, :red }
      inside(10, 10, 50, 50) { fill_rect 0, 0, 320, 200, :green }
      pixel 300, 190, :white
      halt
    end

    assert_equal %i[red green white blue].map { |color| VBlank::Graphics::Color.resolve(color) },
                 [run.screen.pixel(110, 110), run.screen.pixel(30, 30), run.screen.pixel(300, 190), run.screen.pixel(80, 80)]
  end

  # An area off the screen, or of no size, is one nothing is drawn in.
  def test_an_area_off_the_screen_or_of_no_size_takes_no_drawing
    run = checked do
      screen :bitmap
      clear_screen :blue
      inside(-50, -50, 40, 40) { fill_rect(-60, -60, 400, 300, :red) }
      inside(300, 180, 100, 100) { fill_rect 0, 0, 320, 200, :green }
      inside(50, 50, 0, 10) { fill_rect 0, 0, 320, 200, :white }
      halt
    end

    assert_equal [VBlank::Graphics::Color.resolve(:blue), VBlank::Graphics::Color.resolve(:green)],
                 [run.screen.pixel(60, 55), run.screen.pixel(310, 190)]
  end

  # A game whose frames end while an area is open goes on drawing inside it on every pass.
  def test_an_area_stays_open_across_frames
    checked(frames: 5) do
      screen :bitmap
      clear_screen :blue
      x = var :x, 0
      inside 40, 20, 120, 80 do
        game_loop do
          draw_rect_at x, 30, 30, 30, :red
          x += 37
        end
      end
    end
  end

  # One of several pictures, picked by a number the game works out: each in turn, and none for a number
  # that is not one of them.
  def test_one_of_several_pictures_is_drawn_by_its_number
    run = checked(frames: 6) do
      screen :bitmap
      image :red_square, width: 2, height: 2, data: %i[red red red red]
      image :green_square, width: 2, height: 2, data: %i[green green green green]
      image :white_square, width: 2, height: 2, data: %i[white white white white]
      which = var :which, -1
      game_loop do
        clear_screen :black
        blit %i[red_square green_square white_square], 318 + which, 100 + (which * 20), showing: which
        which += 1
      end
    end

    assert_equal 5, run[:which]
  end
end
