# frozen_string_literal: true

require "test_helper"
require "stringio"

# RECTANGLES ON A SUPER FX CARTRIDGE ARE PAINTED BY THE CHIP (Runtime::ChipFill): fill_rect,
# draw_rect_at and pixel on a painted screen. The console hands the chip the rectangle and the
# chip paints it; the picture is the interpreter's on every pass, and a rectangle costs the frame
# a small part of what the console's own processor took.
class TestSNESChipFill < Minitest::Test
  # Rectangles moving over the screen's edges, past them, empty, inside an area with a clear of
  # the area between them, and pixels in the screen's corners.
  def self.edges
    VBlank.game("CHIP RECTANGLES", consoles: %i[snes]) do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :cyan
        draw_rect_at (n * 7) - 30, (n * 5) - 20, (n % 13) + 1, (n % 11) + 3, :red
        draw_rect_at 250 - (n * 3), 220 - (n * 2), 20, 12, :green
        draw_rect_at (n % 9) + 3, 3, 3, 30, :yellow
        draw_rect_at(-5, -5, 300, 2, :white)
        draw_rect_at 0, 0, 0, 10, :white
        draw_rect_at 100, 100, -4, 10, :white
        inside 33, 41, 70, 50 do
          draw_rect_at (n % 40) + 20, 30, 50, 40, :blue
          clear_screen :gray
          draw_rect_at 50, (n % 30) + 30, 9, 9, :magenta
        end
        fill_rect 120, 8, 16, 16, :orange
        pixel 255, 223, :white
        pixel 0, 0, :red
        n += 1
      end
    end
  end

  # One rectangle, 20 pixels square, moving across a screen cleared each pass.
  def self.one_rectangle
    VBlank.game("CHIP ONE RECTANGLE", consoles: %i[snes]) do
      screen :bitmap
      n = var :n, 0
      game_loop do
        clear_screen :black
        draw_rect_at (n & 7) + 10, 40, 20, 20, :green
        n += 1
      end
    end
  end

  # Ten pixels, each in a tile of its own.
  def self.ten_pixels
    VBlank.game("CHIP TEN PIXELS", consoles: %i[snes]) do
      screen :bitmap
      game_loop do
        clear_screen :black
        10.times { |i| pixel (i * 37) & 255, (i * 13) & 127, :white }
      end
    end
  end

  private def lines_spare(game)
    rom = game.build_rom(console: :snes, variant: :superfx, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 10, frames: 20).fewest_lines_spare
  end

  def test_rectangles_the_chip_paints_are_the_interpreters_on_every_pass
    game_player.run(self.class.edges.program(console: :snes, variant: :superfx), frames: 60)
  end

  # The bar sits between what the console's own processor left painting the rectangle and what
  # the chip leaves, so a rectangle painted on the console again fails it.
  def test_a_rectangle_the_chip_paints_leaves_most_of_the_frame
    assert_operator lines_spare(self.class.one_rectangle), :>=, 160
  end

  # The same for ten pixels, each a tile of its own to make ready.
  def test_pixels_the_chip_paints_leave_room
    assert_operator lines_spare(self.class.ten_pixels), :>=, 120
  end
end
