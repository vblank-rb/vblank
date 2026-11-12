# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_backdrops"

# A SCENE SAYS ITS BACKDROP IS A COLOUR OF THE DATA PACK, on the Super Nintendo, whose colour 0
# changes with the rest of a screen's colours: the logos show the pack's first colour, the title
# the second bank's, and a menu that says none the game's, each moved by a tint as the picture is.
class TestPackBackdropsOnTheSuperNintendo < Minitest::Test
  include PackBackdropGames

  private def screen_at(program, frames) = game_player.run(program, frames: frames).screen

  def test_each_scene_shows_the_backdrop_its_screen_takes_from_the_pack
    Dir.mktmpdir do |folder|
      program = scenes_with_backdrops(backdrop_original(folder))

      refute_equal shown(BANKS[0][0]), screen_at(program, 3).pixel(*EMPTY), "the logos', under the tint"
      assert_equal shown(BANKS[1][0]), screen_at(program, TINT_LIFTED_PASS + 3).pixel(*EMPTY), "the title's, the second bank's first"
      assert_equal 0, screen_at(program, MENU_PASS + 4).pixel(*EMPTY), "the menu says none, so the game's"
    end
  end

  def test_a_scene_arriving_under_a_held_tint_shows_its_backdrop_tinted
    Dir.mktmpdir do |folder|
      program = scenes_under_a_held_tint(backdrop_original(folder))

      refute_equal shown(BANKS[1][0]), screen_at(program, TITLE_PASS + 3).pixel(*EMPTY)
      refute_equal 0, screen_at(program, MENU_PASS + 4).pixel(*EMPTY)
    end
  end
end
