# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A SCENE SAYS ITS OWN BACKDROP, as every screen setting a scene says is that scene's: a sky-blue
# title, then a board that says none and so shows the game's. The Advance keeps one backdrop colour
# and is told the scene's as it takes over; the Color keeps it in every colour list, and refuses a
# scene of its own (test/lowering/gbc/vblank/ir/backends/gbc/test_gbc_backdrop.rb).
class TestScreenBackdropOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  private def sky_title = ScreenBackdropGames.title_and_board(title_screen: { backdrop: ScreenBackdropGames::SKY })

  def test_a_scene_says_its_own_backdrop
    assert_equal ScreenBackdropGames::SKY, game_player.run(sky_title, frames: 3).screen.pixel(100, 100), "the title's"
    assert_equal 0, game_player.run(sky_title, frames: 12).screen.pixel(100, 100), "the board says none"
  end

  def test_the_console_shows_each_scenes_backdrop_as_the_interpreter_does
    assert_backends_agree(sky_title, frames: [3, 12], name: "BACKDROPS")
  end

  # UNDER A TINT THAT HOLDS STILL, a scene's backdrop is tinted as its picture is from the frame
  # it arrives, and so is the game's as the next scene puts it back. These scenes send no colours
  # of their own, so nothing but the backdrop changes as one takes over.
  def test_a_scenes_backdrop_arrives_tinted_under_a_tint_that_holds_still
    tinted = ScreenBackdropGames.title_and_board(title_screen: { backdrop: ScreenBackdropGames::SKY }) { tint :red, 50 }

    refute_equal ScreenBackdropGames::SKY, game_player.run(tinted, frames: 3).screen.pixel(100, 100)
    assert_backends_agree(tinted, frames: [2, 3, 7, 8, 12], name: "TINTDROPS")
  end
end
