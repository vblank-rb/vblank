# frozen_string_literal: true

require "test_helper"
require "scene_color_games"

# EACH SCREEN'S COLOURS ARE ITS OWN WHILE IT IS UP. A Genesis shows four palettes of fifteen colours at
# once, and its own games load a screen's palettes as the screen comes up, so a title and the screen
# after it each have the four, less what every screen keeps. Played on every run that plays games as
# the Genesis, each pass held to the interpreter's picture (SceneColorGames sets the game out).
class TestSceneColorsOnTheGenesis < Minitest::Test
  include SceneColorGames

  private def shown(color) = VBlank::Testing.shown(color)

  # The picture of the pass +frames+, read as late as the console shows what the framework draws.
  private def screen_after(program, frames) = game_player.run(program, frames: frames + framework_drawing_lag).screen

  private def assert_scene_shown(screen, scene, message)
    4.times do |cell|
      x = (cell * 8) + 1
      assert_equal shown(SceneColorGames.background_color(scene, x)), screen.pixel(x, 0), "#{message}: the background at (#{x}, 0)"
    end
    SPRITES_AT.each_with_index do |(x, y), which|
      left, right = SceneColorGames.sprite_colors(scene, which)
      assert_equal [shown(left), shown(right)], [screen.pixel(x + 1, y + 1), screen.pixel(x + 5, y + 1)], "#{message}: sprite #{which}"
    end
  end

  def test_each_scene_shows_its_own_colours_and_the_list_every_scene_uses
    Dir.mktmpdir do |folder|
      program = scene_colors_game(folder)

      first = screen_after(program, 2)
      assert_scene_shown(first, 0, "the first scene")
      second = screen_after(program, FIRST_SCENE_AGAIN_PASS - 1)
      assert_scene_shown(second, 1, "the second scene, the fade lifted")
      back = screen_after(program, FIRST_SCENE_AGAIN_PASS + 1)
      assert_scene_shown(back, 0, "the first scene again")
    end
  end

  # The second scene comes in while the screen is faded fully to black: its first frame is black, and
  # each pass after it is held to the interpreter's as the fade lifts.
  def test_a_scene_coming_in_under_a_fade_to_black_is_black_then_its_own_colours
    Dir.mktmpdir do |folder|
      program = scene_colors_game(folder)
      arrived = screen_after(program, SECOND_SCENE_PASS)

      assert_equal shown(:black), arrived.pixel(1, 0), "the second scene's background on its first frame"
      assert_equal shown(:black), arrived.pixel(41, 41), "its sprite"
      game_player.run(program, frames: PASSES_PLAYED)
    end
  end

  # The moon is drawn with the list every scene uses, told to hold :dusk on every even pass (`showing: 0`
  # names :dusk, and 1 names no set, so the colours it was declared with), in both scenes. A list's
  # colours show on the frame of the pass that set them.
  def test_the_list_every_scene_uses_keeps_its_palette_in_both_scenes
    Dir.mktmpdir do |folder|
      program = scene_colors_game(folder)
      x, y = MOON_AT

      [2, 3, FIRST_SCENE_AGAIN_PASS - 2, FIRST_SCENE_AGAIN_PASS - 1].each do |pass|
        held = pass.even? ? DUSK : SCREEN
        assert_equal shown(held[1]), game_player.run(program, frames: pass).screen.pixel(x + 1, y + 1), "the moon after pass #{pass}"
      end
    end
  end
end
