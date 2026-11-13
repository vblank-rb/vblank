# frozen_string_literal: true

require "test_helper"

# A PAINTED SCREEN WHOSE PIXELS ARE SHOWN TWICE AS BIG on the Super Nintendo (`screen :bitmap,
# pixel_size: 2`): the game paints a 128×112 picture and the console shows each of its pixels as a
# square of four, filling its 256×224 screen. Every run that plays games as the Super Nintendo plays
# these, so the cartridge, and the game as C, JavaScript and Ruby, are each held to the interpreter
# pass by pass. What the cartridge copies each frame is
# test/lowering/snes/vblank/ir/backends/snes/test_snes_paint_doubled.rb.
class TestScreenPixelSizeOnTheSuperNintendo < Minitest::Test
  Color = VBlank::Graphics::Color

  FACE = <<~PICTURE.chomp
    .####.
    #.##.#
    ######
    #....#
    .####.
  PICTURE

  # A frame round the edge of the small screen, a block that moves a pixel each pass, a dot in the
  # last corner, a word, a number and a face with see-through pixels that walks off both edges.
  private def game(rows: nil)
    VBlank.game("BIGPIXELS", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2, shown_rows: rows
      image(:face, "." => :transparent, "#" => :orange) { FACE }
      right = screen_width - 1
      bottom = screen_height - 1
      x = var :x, 10
      walk = var :walk, -8
      game_loop do
        clear_screen :blue
        fill_rect 0, 0, screen_width, 2, :white
        fill_rect 0, bottom - 1, screen_width, 2, :white
        pixel right, bottom, :red
        draw_rect_at x, 30, 20, 10, :yellow
        draw_text "HI", 4, 8, :green
        draw_number x, 100, 8, :white
        blit :face, walk, 60
        inside(20, 70, 30, 20) { fill_rect 0, 0, 200, 200, :magenta }
        x += 1
        x = 10 if x > 90
        walk += 3
        walk = -8 if walk > 132
      end
    end
  end

  def test_the_game_is_laid_out_on_a_screen_half_as_wide_and_half_as_tall
    sizes = []
    VBlank.game("BIGPIXELS", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      sizes << screen_width << screen_height
    end.program

    assert_equal [128, 112], sizes
  end

  def test_the_console_shows_the_small_picture_as_the_interpreter_does
    run = game_player.run(game.program(console: :snes), frames: 50)
    screen = run.screen

    assert_equal [128, 112], [screen.width, screen.height]
    assert_equal Color.resolve(:red), screen.pixel(127, 111)
    assert_equal Color.resolve(:white), screen.pixel(64, 0)
    assert_equal Color.resolve(:magenta), screen.pixel(30, 80)
    assert_operator run[:x], :>=, 40, "thirty passes or more were checked"
  end

  # Rows given up are black, and the rest is as the game paints it.
  def test_rows_given_up_are_black
    run = game_player.run(game(rows: 16...96).program(console: :snes), frames: 30)
    column = (0...112).map { |row| run.screen.pixel(50, row) }

    assert_equal [0], (column[0, 16] + column[96..]).uniq
    assert_includes column[16...96], Color.resolve(:blue)
  end
end
