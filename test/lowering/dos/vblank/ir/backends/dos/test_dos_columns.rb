# frozen_string_literal: true

require "test_helper"

# ONE COLUMN OF A PICTURE, STRETCHED, ON A PC, in DOSBox, held to the interpreter on every pass
# (DOS::CheckedRun). What the verb does is in test/all/vblank/builder/test_draw_column_at.rb, which this run
# plays too; these are what is DOS's own: the screen's own edges, heights a wall close by has, an area, and
# the numbers a game can work out wrongly.
class TestDOSColumns < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  # Four rows, each two colours, so a row of the picture shown a row too high or a column too far shows.
  BARS = %i[red yellow green white blue magenta white red].freeze

  private def checked(frames: nil, &game)
    made = VBlank.game("DOSGAME", consoles: %i[dos]) do
      screen :bitmap
      image :bars, width: 2, height: 4, data: BARS
      image(:ghost, "." => :transparent, "W" => :white) { "W\n.\n.\nW\n" }
      clear_screen :gray
      instance_eval(&game)
    end
    DOS::CheckedRun.new.run(made.program(console: :dos), frames: frames)
  end

  private def colors(*names) = names.map { |name| VBlank::Graphics::Color.resolve(name) }

  # A column twice as tall as the picture shows each of its rows twice, and its other column to the right.
  def test_a_column_stretched_shows_each_row_of_the_picture_in_turn
    run = checked do
      draw_column_at :bars, slice: 0, x: 10, top: 20, height: 8
      draw_column_at :bars, slice: 1, x: 11, top: 20, height: 8
      halt
    end

    assert_equal colors(:red, :red, :green, :blue, :white, :gray), [20, 21, 22, 24, 27, 28].map { |y| run.screen.pixel(10, y) }
    assert_equal colors(:yellow, :white, :magenta, :red), [20, 22, 24, 26].map { |y| run.screen.pixel(11, y) }
  end

  # Past every edge of a screen 320 wide, squashed to less than the picture, far taller than the screen,
  # see-through, a strip, a column the picture does not have, and heights and places that are no use.
  def test_columns_at_the_edges_and_with_numbers_a_game_can_get_wrong
    run = checked do
      draw_column_at :bars, slice: 0, x: 319, top: -3, height: 9
      draw_column_at :bars, slice: 1, x: 320, top: 0, height: 9
      draw_column_at :bars, slice: 0, x: -2, top: 190, height: 400, width: 5
      draw_column_at :bars, slice: 1, x: 316, top: 100, height: 3, width: 9
      draw_column_at :bars, slice: 0, x: 50, top: -100_000, height: 200_150
      draw_column_at :bars, slice: 1, x: 60, top: -2_000_000_000, height: 2_000_000_100
      draw_column_at :ghost, slice: 0, x: 70, top: 5, height: 40, width: 4
      draw_column_at :bars, slice: 7, x: 80, top: 5, height: 4
      draw_column_at :bars, slice: -3, x: 81, top: 5, height: 4
      draw_column_at :bars, slice: 0, x: 90, top: 5, height: 0
      draw_column_at :bars, slice: 0, x: 91, top: 5, height: -8
      draw_column_at :bars, slice: 0, x: 92, top: 5000, height: 8
      draw_column_at :bars, slice: 0, x: 2_000_000_000, top: 5, height: 8, width: 200
      halt
    end

    assert_equal colors(:yellow, :red, :gray), [[80, 5], [81, 5], [90, 5]].map { |x, y| run.screen.pixel(x, y) }
  end

  # Columns a game moves and resizes pass by pass, inside an area that cuts them on every side.
  def test_columns_that_grow_and_move_inside_an_area
    run = checked(frames: 40) do
      tall = var :tall, 1
      at = var :at, 30
      game_loop do
        clear_screen :gray
        inside(40, 60, 100, 70) do
          draw_column_at :bars, slice: tall & 1, x: at, top: 95 - tall, height: tall * 2, width: 3
          draw_column_at :ghost, slice: 0, x: at + 20, top: 60, height: tall + 60
        end
        tall += 3
        at += 3
      end
    end

    assert_equal 121, run[:tall]
  end

  # A strip far wider than the screen, begun far to its left, is cut to the screen as any strip is.
  def test_a_strip_wider_than_the_screen_is_cut_to_it
    run = checked do
      draw_column_at :bars, slice: 1, x: -69_000, top: 10, height: 4, width: 70_000
      halt
    end

    assert_equal colors(:yellow, :yellow, :gray), [[0, 10], [319, 10], [319, 14]].map { |x, y| run.screen.pixel(x, y) }
  end
end
