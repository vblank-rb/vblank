# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_backdrops"

# A SCENE SAYS ITS BACKDROP IS A COLOUR OF THE DATA PACK, as the original's screens each show the
# first colour of the colours they loaded: the logos the pack's first colour, the title the second
# bank's, and a menu that says none the game's. A tint a game fades its screen in with moves the
# backdrop with the picture, on the frame it moves the picture. The Advance keeps one backdrop
# colour and is told the scene's as it takes over; a console that keeps one for the whole game
# refuses a scene's own.
class TestPackBackdropsOnTheAdvance < Minitest::Test
  include PackBackdropGames
  include VBlank::Testing::Pictures

  private def screen_at(program, frames) = game_player.run(program, frames: frames).screen

  def test_each_scene_shows_the_backdrop_its_screen_takes_from_the_pack
    Dir.mktmpdir do |folder|
      program = scenes_with_backdrops(backdrop_original(folder))

      assert_equal BANKS[1][0], screen_at(program, TINT_LIFTED_PASS + 2).pixel(*EMPTY), "the title's, the second bank's first"
      assert_equal 0, screen_at(program, MENU_PASS + 3).pixel(*EMPTY), "the menu says none, so the game's"
    end
  end

  # Under a tint the backdrop is moved as far toward the tint's colour as a drawn pixel is, on
  # the same frame, and both are as the pack has them on the frame the tint has lifted.
  def test_a_tint_moves_the_backdrop_with_the_picture_on_the_same_frame
    Dir.mktmpdir do |folder|
      program = scenes_with_backdrops(backdrop_original(folder))
      (2...TITLE_PASS).each do |frames|
        screen = screen_at(program, frames)

        refute_equal BANKS[0][0], screen.pixel(*EMPTY), "the backdrop under the tint after #{frames} frames"
        refute_equal BANKS[0][DRAWN_PLACE], screen.pixel(*DRAWN), "a drawn pixel under the tint after #{frames} frames"
      end
      lifted = screen_at(program, TINT_LIFTED_PASS + 2)

      assert_equal BANKS[1][0], lifted.pixel(*EMPTY)
      assert_equal BANKS[0][DRAWN_PLACE], lifted.pixel(*DRAWN), "the cell is drawn from bank 0 in every scene"
    end
  end

  # The logos under the tint, the title arriving under it, the tint lifting, and the menu.
  def test_the_console_shows_each_scenes_backdrop_under_the_tint_as_the_interpreter_does
    Dir.mktmpdir do |folder|
      program = scenes_with_backdrops(backdrop_original(folder))

      assert_backends_agree(program, frames: 2..(MENU_PASS + 3), name: "PACKDROP")
    end
  end

  # A tint that holds still walks no colours, so a scene arriving is all that writes its backdrop.
  def test_a_scene_arriving_under_a_held_tint_shows_its_backdrop_tinted
    Dir.mktmpdir do |folder|
      program = scenes_under_a_held_tint(backdrop_original(folder))

      refute_equal BANKS[1][0], screen_at(program, TITLE_PASS + 2).pixel(*EMPTY)
      assert_backends_agree(program, frames: [3, TITLE_PASS, TITLE_PASS + 1, TITLE_PASS + 3, MENU_PASS + 1, MENU_PASS + 3], name: "HELDDROP")
    end
  end

  # A fade takes the tint's place, and the colours go back as drawn: the scene's backdrop too.
  def test_a_fade_taking_the_tints_place_keeps_each_scenes_backdrop
    Dir.mktmpdir do |folder|
      program = scenes_under_a_tint_then_a_fade(backdrop_original(folder))

      assert_backends_agree(program, frames: [2, FADE_PASS, FADE_PASS + 1, FADE_PASS + 2, TITLE_PASS + 2, MENU_PASS + 3], name: "FADEDROP")
    end
  end
end
