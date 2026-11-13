# frozen_string_literal: true

require "test_helper"

# A CROWDED LINE ON THE GENESIS. As it draws a line of the screen the console takes the first 20
# entries of its sprite table that reach the line, front-most first, and leaves the rest out of
# that line. Then it draws 320 pixels of them, front-most first: each entry spends its whole width,
# the pixels off the screen and the see-through ones too, and the entry that crosses 320 is drawn
# only as far as the pixels left. A picture drawn all over up to 32 wide is one entry.
class TestSpritesOnALineOnTheGenesis < Minitest::Test
  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)
  RED_DOT_ROWS = (["r" * 8] * 8).join("\n")
  GREEN_BAR_ROWS = (["g" * 32] * 8).join("\n")

  private def program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :genesis))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red 8×8 furthest back, four lines above a row of 20 green ones beside it: 21 sprites on lines
  # 50..53, the red one alone on 46..49.
  def test_the_twenty_first_sprite_on_a_line_is_left_out_of_that_line
    game = program do
      screen :tiled
      image(:red_dot, "r" => :red) { (["r" * 8] * 8).join("\n") }
      image(:green_dot, "g" => :green) { (["g" * 8] * 8).join("\n") }
      sprite :red_dot, at: [0, 46]
      20.times { |i| sprite :green_dot, at: [10 + (i * 15), 50] }
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(3, 47), "the red dot is alone on line 47"
    refute_equal RED, screen.pixel(3, 51), "the red dot is the twenty-first on line 51, so it is left out"
    assert_equal GREEN, screen.pixel(13, 51), "the first green dot is drawn"
    assert_equal GREEN, screen.pixel(10 + (19 * 15) + 3, 51), "and the last"
  end

  # Thirteen green bars of 24 in front of a red one: 312 pixels, so the red bar furthest back is
  # drawn only its first eight.
  def test_the_sprite_that_crosses_three_hundred_twenty_pixels_is_cut
    game = program do
      screen :tiled
      image(:red_bar, "r" => :red) { (["r" * 24] * 8).join("\n") }
      image(:green_bar, "g" => :green) { (["g" * 24] * 8).join("\n") }
      sprite :red_bar, at: [0, 50]
      13.times { |i| sprite :green_bar, at: [24 + (i * 22), 50] }
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(3, 51), "the red bar's first eight pixels are drawn"
    refute_equal RED, screen.pixel(11, 51), "the rest of it is left out"
    refute_equal RED, screen.pixel(20, 51), "to its end"
  end

  # A bar four pixels on the screen at the left spends its whole 32: with nine more it leaves no
  # pixels for the dot furthest back. Without it the dot is drawn.
  def test_a_sprite_off_the_edge_spends_its_whole_width
    [true, false].each do |edge|
      game = program do
        screen :tiled
        image(:red_dot, "r" => :red) { RED_DOT_ROWS }
        image(:green_bar, "g" => :green) { GREEN_BAR_ROWS }
        sprite :red_dot, at: [310, 50]
        9.times { |i| sprite :green_bar, at: [10 + (i * 33), 50] }
        sprite :green_bar, at: [-28, 50] if edge
        game_loop {}
      end
      screen = game_player.run(game, frames: 3).screen

      assert_equal !edge, screen.pixel(313, 51) == RED, "the dot is drawn only without the bar at the edge (edge: #{edge})"
    end
  end

  # THE TABLE'S 80 ROWS. The cartridge places the sprite furthest back first, so with more pieces than
  # rows the ones IN FRONT find it full. A bar of 40 is two rows, one of 32 and one of 8: 39 bars
  # take 78, a bar in front takes the last two, and a dot in front of that finds none.
  def test_past_a_full_table_the_sprite_in_front_is_left_out
    game = program do
      screen :tiled
      image(:bar, "r" => :red) { (["r" * 40] * 8).join("\n") }
      image(:dot, "g" => :green) { (["g" * 8] * 8).join("\n") }
      39.times { |i| sprite :bar, at: [(i % 7) * 44, (i / 7) * 10] }
      sprite :bar, at: [100, 200]
      sprite :dot, at: [200, 200]
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(3, 3), "the bar furthest back is drawn"
    assert_equal RED, screen.pixel(135, 203), "the bar in front of the others takes the last rows"
    refute_equal GREEN, screen.pixel(203, 203), "the dot in front finds the table full"
  end

  # A crowd of big things moving down a line a frame, so the crowded lines change every frame.
  def test_a_moving_crowd_of_big_things
    game = program do
      screen :tiled
      image(:block, "r" => :red) { (["r" * 24] * 24).join("\n") }
      crowd = pool :crowd, x: 0, y: 0, capacity: 40, image: :block
      40.times { |i| crowd.spawn(x: (i * 13) % 300, y: (i * 37) % 120) }
      game_loop { crowd.each { |c| c.y = (c.y + 1) & 127 } }
    end
    screen = game_player.run(game, frames: 6).screen

    red = (0...144).step(4).any? { |y| (0...300).step(4).any? { |x| screen.pixel(x, y) == RED } }
    assert red, "the crowd is drawn"
  end
end
