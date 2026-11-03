# frozen_string_literal: true

require "test_helper"
require "sprite_over_picture_games"

# A sprite shown over a painted picture (`sprite ..., over_picture: true`) turned and resized: the
# Advance turns and resizes the sprites it draws, and the other consoles refuse both. What every
# console does with such a sprite is in test/all/vblank/builder/test_sprite_over_picture.rb.
class TestSpriteOverPictureOnTheAdvance < Minitest::Test
  include SpriteOverPictureGames

  def test_a_sprite_twice_its_size_covers_twice_the_box_about_its_middle
    screen = game_player.run(changed_program { |gun| gun.scale(2.0) }, frames: 6).screen
    left, top = HALVES_AT

    assert_equal Color.resolve(:red), screen.pixel(left - 6, top - 6), "top left, past the drawn box"
    assert_equal Color.resolve(:blue), screen.pixel(left - 6, top + 21), "bottom left, past the drawn box"
    assert_equal Color.resolve(FIELD), screen.pixel(left - 10, top - 10), "outside the doubled box"
  end

  def test_a_sprite_turned_round_shows_its_halves_the_other_way_up
    screen = game_player.run(changed_program { |gun| gun.face_angle(180) }, frames: 6).screen
    left, top = HALVES_AT

    assert_equal Color.resolve(:blue), screen.pixel(left + 8, top + 3), "the top, once the bottom"
    assert_equal Color.resolve(:red), screen.pixel(left + 8, top + 12), "the bottom, once the top"
  end
end
