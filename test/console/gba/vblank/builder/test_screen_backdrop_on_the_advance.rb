# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A scene says its own backdrop, as every screen setting a scene says is that scene's: a sky-blue
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

  # Under a tint that holds still, a scene's backdrop is tinted as its picture is from the frame
  # it arrives, and so is the game's as the next scene puts it back. These scenes send no colours
  # of their own, so nothing but the backdrop changes as one takes over.
  def test_a_scenes_backdrop_arrives_tinted_under_a_tint_that_holds_still
    tinted = ScreenBackdropGames.title_and_board(title_screen: { backdrop: ScreenBackdropGames::SKY }) { tint :red, 50 }

    refute_equal ScreenBackdropGames::SKY, game_player.run(tinted, frames: 3).screen.pixel(100, 100)
    assert_backends_agree(tinted, frames: [2, 3, 7, 8, 12], name: "TINTDROPS")
  end

  # Under a tint that moves each pass, the scene's own backdrop is tinted from the scene's colour, not
  # the game's, on every pass, and the game's comes back tinted when the board takes over.
  def test_a_scenes_backdrop_follows_a_tint_that_moves_every_pass
    assert_backends_agree(tinted_sky_title(:moving), frames: [3, 5, 7, 9, 11, 14, 16], name: "MOVINGDROP")
  end

  # A fade takes the tint's place (the colour tables are put back as drawn, then faded), and the scene's
  # own backdrop is put back and faded with them, not the game's.
  def test_a_fade_taking_a_tints_place_fades_the_scenes_own_backdrop
    assert_backends_agree(tinted_sky_title(:fading), frames: [3, 5, 7, 9, 11, 14, 16], name: "FADEDROP")
  end

  # A sky-blue title, which names its own backdrop and sends no colours of its own, for twelve passes,
  # then a board that names none. +kind+ :moving tints toward red by four more each pass; :fading holds a
  # tint for five passes, then fades toward black, the fade taking the tint's place.
  private def tinted_sky_title(kind)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, 0
      tick = 0
      scene(:title) do
        screen(:tiled, backdrop: ScreenBackdropGames::SKY)
        background :title, tiles: :corner_set, map: ["c"]
      end
      scene(:board) { background :board, tiles: :corner_set, map: ["c"] }
      game_loop do
        tick += 1
        if kind == :moving
          tint :red, tick * 4
        elsif tick < 6
          tint :red, 50
        else
          fade :black, tick * 3
        end
        state = 1 if tick == 12
        call({ 0 => :title, 1 => :board }, number: :state)
      end
    end
    b.finalize_program
    b.program
  end
end
