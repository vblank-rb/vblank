# frozen_string_literal: true

require "test_helper"
require "status_bar_games"

# What a status bar does on the PlayStation, which the Color refuses (Checks::StatusBarCannotShare): a
# sprite stacked behind the field, which the PlayStation's build draws a level of the stack at a time
# (Runtime::Tiles' rt_tiles_draw), with the bar drawn first and the field kept above the bar's top.
class TestStatusBarOnThePlayStation < Minitest::Test
  include SpriteBehindFieldOverBarTests

  # A bar told to cover sprites hides one stacked behind the field too, once it is drawn again over them.
  def test_a_bar_covering_sprites_hides_a_sprite_behind_the_field
    prog = sprite_behind_field_game do |bar, step|
      bar.covers_sprites = true if step == 3
    end

    assert_equal WHITE, picture(prog, 2).pixel(44, screen_height - 12), "over the bar before it covers"
    assert_equal GREEN, picture(prog, 6).pixel(44, screen_height - 12), "hidden once it covers"
  end

  # Whether a bar covers sprites is its own: a scene's bar told to cover leaves the next scene's bar, never
  # told, showing the sprite over it (Reference#exec_place_bar keeps it by the bar's name). Here, not in
  # test/all/, while the Color's and the Super Nintendo's builds keep one setting for every bar.
  def test_a_bar_covering_sprites_leaves_the_next_scenes_bar_uncovered
    prog = two_scene_bars_game

    assert_equal GREEN, picture(prog, 3).pixel(44, screen_height - 8), "the first scene's bar covers the sprite"
    assert_equal WHITE, picture(prog, 8).pixel(44, screen_height - 8), "the second scene's bar does not"
  end
end
