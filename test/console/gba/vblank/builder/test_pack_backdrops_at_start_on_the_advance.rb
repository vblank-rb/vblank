# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_backdrops"

# EACH SCENE'S BACKDROP FROM THE PACK, ITS PACK LEFT OUT: the three scenes of PackBackdropGames
# built with `pack_at_start: true` and handed the pack file show what the all-in-one build shows on
# every frame. Each scene is a background read as the game starts and a backdrop read then too, as
# an original's logo screen is: a field of its first colour behind its logos.
#
# The answer key is the all-in-one build. Only a build for a computer leaves its pack out, and a
# scene's own backdrop is the Advance's, so this is played by the interpreter and by the game as C,
# JavaScript and Ruby built for the Advance.
class TestPackBackdropsAtStartOnTheAdvance < Minitest::Test
  include PackBackdropGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The scenes +build+ makes (handed the original and how to build), built both ways, show one
  # picture after each of +frames+. Hands back what the all-in-one build shows where no tile draws
  # after each.
  private def assert_scenes_play_alike(frames)
    Dir.mktmpdir do |folder|
      from = backdrop_original(folder)
      whole = yield(from, VBlank::Cartridge::Options.new)
      left_out = yield(from, LEFT_OUT)
      file = backdrop_pack_file(from)

      frames.to_h do |count|
        shown = game_player.run(whole, frames: count).screen
        assert_equal shown.to_a, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "after #{count} frames the game handed its pack shows what the all-in-one build shows"
        [count, shown.pixel(*EMPTY)]
      end
    end
  end

  # The logos under the tint, the title arriving under it, the tint lifting, and the menu.
  def test_each_scenes_backdrop_read_at_start_shows_under_a_tint_as_the_all_in_one_build
    frames = [2, 3, TITLE_PASS, TITLE_PASS + 1, TITLE_PASS + 2, TINT_LIFTED_PASS + 2, MENU_PASS + 1, MENU_PASS + 3]
    empty = assert_scenes_play_alike(frames) { |from, options| scenes_with_backdrops(from, options: options) }

    assert_equal BANKS[1][0], empty.fetch(TINT_LIFTED_PASS + 2), "the title's, the second bank's first"
    assert_equal 0, empty.fetch(MENU_PASS + 3), "the menu names none, so the game's"
    refute_equal BANKS[0][0], empty.fetch(3), "the logos' backdrop is under the tint"
  end

  # A tint that holds still walks no colours, so a scene arriving is all that writes its backdrop.
  def test_a_scene_arriving_under_a_held_tint_read_at_start_shows_as_the_all_in_one_build
    frames = [3, TITLE_PASS, TITLE_PASS + 1, TITLE_PASS + 3, MENU_PASS + 1, MENU_PASS + 3]
    empty = assert_scenes_play_alike(frames) { |from, options| scenes_under_a_held_tint(from, options: options) }

    refute_equal BANKS[1][0], empty.fetch(TITLE_PASS + 3), "the title's backdrop is under the tint"
  end

  # A fade takes the tint's place, and the colours go back as drawn: the scene's backdrop too.
  def test_a_fade_taking_the_tints_place_read_at_start_shows_as_the_all_in_one_build
    assert_scenes_play_alike([2, FADE_PASS, FADE_PASS + 1, FADE_PASS + 2, TITLE_PASS + 2, MENU_PASS + 3]) do |from, options|
      scenes_under_a_tint_then_a_fade(from, options: options)
    end
  end
end
