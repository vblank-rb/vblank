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

  WALL = <<~PICTURE.chomp
    rrggbbyy
    rrggbbyy
    ww..wwww
    rrggbbyy
  PICTURE

  BALL = <<~PICTURE.chomp
    .##.
    ####
    ####
    .##.
  PICTURE

  # Columns two wide from off the left edge to off the right, stretched taller than the screen
  # (cut at its top and its bottom) and shorter, over the whole screen.
  def test_wide_columns_cut_at_every_edge_show_as_the_interpreter_does
    game = VBlank.game("BIGCUTS", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      image(:wall, "r" => :red, "g" => :green, "b" => :blue, "y" => :yellow, "w" => :white,
                   "." => :transparent) { WALL }
      step = var :step, 0
      game_loop do
        step += 1
        clear_screen :black
        repeat(66) do |column|
          tall = (((column * 7) + (step * 11)) % 200) + 1
          draw_column_at :wall, slice: column % 8, x: (column * 2) - 3, top: 56 - (tall / 2), height: tall, width: 2
        end
      end
    end
    run = game_player.run(game.program(console: :snes), frames: 30)

    assert_operator run[:step], :>=, 3, "three passes or more were checked"
    assert_includes [0, 111].flat_map { |y| (0...128).map { |x| run.screen.pixel(x, y) } }, Color.resolve(:red),
                    "a column reaches the top or the bottom row"
  end

  # A view of walls a column at a time, as a first-person game draws one: in the top half every
  # column of the small screen is a slice of a wall stretched to a height that changes across the
  # view and from pass to pass, with see-through pixels. The bottom half
  # is walls drawn once, and a sprite walks over them, its patch kept and put back each pass, so
  # what it passes over comes back as it was.
  private def walls_game
    VBlank.game("BIGWALLS", consoles: %i[snes]) do
      screen :bitmap, pixel_size: 2
      image(:wall, "r" => :red, "g" => :green, "b" => :blue, "y" => :yellow, "w" => :white,
                   "." => :transparent) { WALL }
      image(:ball, "#" => :magenta, "." => :transparent) { BALL }
      step = var :step, 0
      clear_screen :black
      fill_rect 0, 56, screen_width, 56, :gray
      repeat(screen_width) do |column|
        draw_column_at :wall, slice: column % 8, x: column, top: 60 + (column % 9), height: 30 - (column % 5)
      end
      ball = sprite :ball, at: [-3, 70]
      game_loop do
        step += 1
        fill_rect 0, 0, screen_width, 56, :black
        repeat(screen_width) do |column|
          tall = ((column + (step * 3)) % 52) + 4
          draw_column_at :wall, slice: column % 8, x: column, top: 28 - (tall / 2), height: tall
        end
        # A column cut by an area, at its edge.
        inside(10, 6, 40, 30) { draw_column_at :wall, slice: 3, x: 9 + (step % 42), top: 0, height: 50, width: 2 }
        ball.move_to(((step * 2) % 140) - 3, 70)
      end
    end
  end

  def test_wall_columns_and_a_sprite_over_them_show_as_the_interpreter_does
    run = game_player.run(walls_game.program(console: :snes), frames: 40)

    assert_operator run[:step], :>=, 5, "five passes or more were checked"
    refute_empty (0...128).map { |x| run.screen.pixel(x, 28) }.uniq - [0]
    ball_rows = (70...74).flat_map { |y| (0...128).map { |x| run.screen.pixel(x, y) } }
    assert_includes ball_rows, Color.resolve(:magenta), "the sprite shows over the walls"
  end
end
