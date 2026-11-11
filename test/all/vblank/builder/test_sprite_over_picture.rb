# frozen_string_literal: true

require "test_helper"
require "sprite_over_picture_games"

# `sprite ..., over_picture: true` on a bitmap screen: the console's own sprite, drawn over the
# picture the game paints and never into it. Read through what the player sees. A sprite of this
# kind turned and resized is in test/console/gba/vblank/builder/test_sprite_over_picture_on_the_advance.rb.
class TestSpriteOverPicture < Minitest::Test
  include SpriteOverPictureGames

  def test_the_sprite_shows_over_a_picture_painted_again_every_pass
    screen = game_player.run(over_picture_program, frames: 6).screen

    STRIPE_ROWS.each_with_index do |color, band|
      8.times do |col|
        assert_equal Color.resolve(color), screen.pixel(START[0] + col, START[1] + (band * 2) + 1),
                     "sprite pixel (#{col},#{(band * 2) + 1})"
      end
    end
    assert_equal Color.resolve(:yellow), screen.pixel(START[0] + 3, START[1] + 7), "the bar through the see-through band"
    assert_equal Color.resolve(:yellow), screen.pixel(START[0] - 1, START[1]), "the bar beside the sprite"
    assert_equal Color.resolve(FIELD), screen.pixel(START[0] + 3, START[1] + 11), "the field under the bar"
  end

  def test_a_moving_sprite_leaves_nothing_behind
    screen = game_player.run(over_picture_program(step: 3), frames: 8).screen

    assert_equal 16, count_color(screen, :red), "one band of red, wherever the sprite is now"
    assert_equal Color.resolve(:yellow), screen.pixel(START[0], START[1]), "the bar where the sprite started"
  end

  def test_the_sprite_shows_on_both_pages_of_a_tear_free_screen
    player = game_player
    seen = []
    player.each_vblank { |frame| seen << player.screen.pixel(START[0], START[1]) if frame > 3 }
    player.run(over_picture_program(tear_free: true), frames: 7)

    refute_empty seen
    assert_equal [Color.resolve(:red)] * seen.length, seen, "the sprite on every frame, whichever page is up"
  end

  def test_a_sprite_over_the_picture_draws_with_another_list_of_colors
    screen = game_player.run(recolored_program, frames: 4).screen

    assert_equal Color.resolve(:yellow), screen.pixel(41, 41), "the first place of the list"
    assert_equal Color.resolve(:white), screen.pixel(45, 41), "and the second"
  end

  # Two sprites that cross over a picture painted once: the one declared later is in front where they
  # meet, and the picture under where they have been is as it was painted.
  def test_sprites_that_cross_are_drawn_in_order_over_a_picture_left_as_it_was
    played = game_player.run(blocks_program { |red, green| [red.x += 2, green.x -= 2] }, frames: 9 + framework_drawing_lag)
    red, green = played.sprites
    meet = [red.x, green.x].max

    assert_equal %i[red_block green_block], [red.picture, green.picture]
    assert_operator (red.x - green.x).abs, :<, 8, "the two overlap by now"
    assert_equal Color.resolve(:green), played.screen.pixel(meet, 50), "the later sprite in front where they meet"
    assert_equal Color.resolve(:yellow), played.screen.pixel(20, 50), "the bar where no sprite is"
  end

  # A sprite part way off an edge of the screen shows the part of itself still on it.
  def test_a_sprite_part_way_off_an_edge_shows_what_is_left_of_it
    screen = game_player.run(blocks_program(red_at: [-3, 46], green_at: [100, -3]), frames: 3 + framework_drawing_lag).screen

    assert_equal ([Color.resolve(:red)] * 5) + [Color.resolve(:yellow)], (0..5).map { |x| screen.pixel(x, 50) }
    assert_equal ([Color.resolve(:green)] * 5) + [Color.resolve(:blue)], (0..5).map { |y| screen.pixel(104, y) }
  end

  # A sprite switched off is not drawn, and is drawn again once it is switched on.
  def test_a_sprite_hidden_is_not_drawn_until_it_is_shown_again
    player = game_player
    seen = []
    player.each_vblank { seen << player.sprites.size }
    program = blocks_program do |red, _green, passes|
      red.hide if passes == 2
      red.show if passes == 6
    end
    player.run(program, frames: 10)

    # From the first frame that shows them, since a console's first frames come before its first placing.
    assert_equal [2, 1, 2], seen.drop_while(&:zero?).chunk_while { |a, b| a == b }.map(&:first)
  end

  # Two 8x8 blocks, red then green, over a blue field with a yellow bar painted once before the loop. The
  # block is handed both sprites and a count of passes, and what it does is each pass's own.
  private def blocks_program(red_at: [20, 46], green_at: [56, 46], &each_pass)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :bitmap
      image :red_block, width: 8, height: 8, data: [:red] * 64
      image :green_block, width: 8, height: 8, data: [:green] * 64
      clear_screen :blue
      fill_rect 0, 44, screen_width, 12, :yellow
      red = sprite :red_block, at: red_at, over_picture: true
      green = sprite :green_block, at: green_at, over_picture: true
      passes = var :passes, 0
      game_loop do
        instance_exec(red, green, passes, &each_pass) if each_pass
        passes += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  private def count_color(screen, color)
    want = Color.resolve(color)
    count = 0
    240.times { |x| 160.times { |y| count += 1 if screen.pixel(x, y) == want } }
    count
  end
end
