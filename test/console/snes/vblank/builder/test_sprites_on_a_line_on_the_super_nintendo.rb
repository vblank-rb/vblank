# frozen_string_literal: true

require "test_helper"

# A CROWDED LINE ON THE SUPER NINTENDO. As it draws a line of the screen the console takes the first
# 32 entries of its sprite table that reach the line, front-most first, and leaves the rest out of
# that line. Then it fetches their pictures eight pixels at a time, starting from the entry furthest
# back, and has time for 34 of those slivers: a sliver off the screen is not fetched. So past 32
# sprites the one furthest back goes, and past 34 slivers the one IN FRONT loses its right-hand
# slivers first. A picture of 16×16 drawn all over is one entry of two slivers.
class TestSpritesOnALineOnTheSuperNintendo < Minitest::Test
  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  GREEN_DOT_ROWS = (["g" * 8] * 8).join("\n")
  RED_BAR_ROWS = (["r" * 16] * 8).join("\n")

  private def program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red 8×8 furthest back, four lines above a row of 32 green ones beside it: 33 sprites on lines
  # 50..53, the red one alone on 46..49.
  def test_the_thirty_third_sprite_on_a_line_is_left_out_of_that_line
    game = program do
      screen :tiled
      image(:red_dot, "r" => :red) { (["r" * 8] * 8).join("\n") }
      image(:green_dot, "g" => :green) { (["g" * 8] * 8).join("\n") }
      sprite :red_dot, at: [0, 46]
      32.times { |i| sprite :green_dot, at: [8 + (i * 7), 50] }
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(3, 47), "the red dot is alone on line 47"
    refute_equal RED, screen.pixel(3, 51), "the red dot is the thirty-third on line 51, so it is left out"
    assert_equal GREEN, screen.pixel(11, 51), "the first green dot is drawn"
    assert_equal GREEN, screen.pixel(8 + (31 * 7) + 3, 51), "and the last"
  end

  # Seventeen green squares, 34 slivers, and a red square in front of them all, four lines lower:
  # on the lines all eighteen share, the red one is fetched last and finds no time left.
  def test_the_sprite_in_front_loses_its_slivers_past_thirty_four
    test = self
    game = program do
      screen :tiled
      image(:red_square, "r" => :red) { test.square_rows(:red) }
      image(:green_square, "g" => :green) { test.square_rows(:green) }
      17.times { |i| sprite :green_square, at: [i * 14, 100] }
      sprite :red_square, at: [240, 104]
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    refute_equal RED, screen.pixel(243, 105), "the red square's left sliver is left out of line 105"
    refute_equal RED, screen.pixel(251, 105), "and its right"
    assert_equal RED, screen.pixel(243, 117), "below the crowd it is drawn"
    assert_equal GREEN, screen.pixel(3, 105), "the green square furthest back is drawn"
  end

  # A square only four pixels on the screen at the left is fetched one sliver, not two, so beside
  # sixteen squares it leaves the red square in front one sliver: its left.
  def test_a_sliver_off_the_screen_takes_no_time
    test = self
    game = program do
      screen :tiled
      image(:red_square, "r" => :red) { test.square_rows(:red) }
      image(:green_square, "g" => :green) { test.square_rows(:green) }
      sprite :green_square, at: [-12, 100]
      16.times { |i| sprite :green_square, at: [8 + (i * 14), 100] }
      sprite :red_square, at: [238, 100]
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(241, 105), "the red square's left sliver is the thirty-fourth"
    refute_equal RED, screen.pixel(250, 105), "its right is the thirty-fifth"
    assert_equal GREEN, screen.pixel(1, 105), "the square at the edge is drawn"
  end

  # A crowd of squares moving down a line a frame, so the crowded lines change every frame.
  def test_a_moving_crowd_of_squares
    test = self
    game = program do
      screen :tiled
      image(:block, "r" => :red) { test.square_rows(:red) }
      crowd = pool :crowd, x: 0, y: 0, capacity: 40, image: :block
      40.times { |i| crowd.spawn(x: (i * 13) % 240, y: (i * 37) % 120) }
      game_loop { crowd.each { |c| c.y = (c.y + 1) & 127 } }
    end
    screen = game_player.run(game, frames: 6).screen

    red = (0...144).step(4).any? { |y| (0...240).step(4).any? { |x| screen.pixel(x, y) == RED } }
    assert red, "the crowd is drawn"
  end

  # THE TABLE'S 128 ROWS. The cartridge places the sprite furthest back first, so with more pieces
  # than rows the ones IN FRONT find it full. 65 bars of 16×8 are two rows each, 130: the bar in
  # front of them all is not drawn.
  def test_past_a_full_table_the_sprite_in_front_is_left_out
    game = program do
      screen :tiled
      image(:bar, "r" => :red) { (["r" * 16] * 8).join("\n") }
      65.times { |i| sprite :bar, at: [(i % 14) * 18, (i / 14) * 12] }
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(3, 3), "the bar furthest back is drawn"
    assert_equal RED, screen.pixel((63 % 14 * 18) + 11, (63 / 14 * 12) + 3), "the bar behind the last fills the table"
    refute_equal RED, screen.pixel((64 % 14 * 18) + 3, (64 / 14 * 12) + 3), "the bar in front finds it full"
  end

  # In a game with squares of 16×16, the cartridge asks every piece about a square's reach, so a
  # dot just off the left edge takes a row and draws nothing. With it, a square and 63 bars fill the
  # table and the bar in front has no row; without it, the bar in front has one, for its left half.
  def test_a_dot_just_off_the_edge_takes_a_row_beside_squares
    test = self
    [true, false].each do |dot|
      game = program do
        screen :tiled
        image(:square, "g" => :green) { test.square_rows(:green) }
        image(:dot, "g" => :green) { GREEN_DOT_ROWS }
        image(:bar, "r" => :red) { RED_BAR_ROWS }
        sprite :square, at: [200, 180]
        sprite :dot, at: [-12, 180] if dot
        63.times { |i| sprite :bar, at: [(i % 14) * 18, (i / 14) * 12] }
        sprite :bar, at: [100, 200]
        game_loop {}
      end
      screen = game_player.run(game, frames: 3).screen

      assert_equal !dot, screen.pixel(103, 203) == RED, "the front bar's left half is drawn only without the dot (dot: #{dot})"
      refute_equal RED, screen.pixel(111, 203), "its right half never is (dot: #{dot})"
    end
  end

  # The rows of a square of 16×16 drawn all over in +color+'s letter, for a game block.
  def square_rows(color) = ([(color == :red ? "r" : "g") * 16] * 16).join("\n")
end
