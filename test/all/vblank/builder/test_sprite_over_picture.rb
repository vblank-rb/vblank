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

  private def count_color(screen, color)
    want = Color.resolve(color)
    count = 0
    240.times { |x| 160.times { |y| count += 1 if screen.pixel(x, y) == want } }
    count
  end
end
