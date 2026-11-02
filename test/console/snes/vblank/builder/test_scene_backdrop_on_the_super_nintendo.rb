# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A SCENE'S OWN BACKDROP. Colour 0 of the Super Nintendo's colour memory is what shows wherever
# nothing is drawn, and it can change with the rest of a screen's colours, as the console's own
# games change it. A title of a blue sky hands over to a stage of black, and a scene that says no
# backdrop shows the game's.
class TestSceneBackdropOnTheSuperNintendo < Minitest::Test
  SKY = ScreenBackdropGames::SKY
  OUT_OF_THE_TILE = [100, 100].freeze

  private def shown_by(prog, frames) = game_player.run(prog, frames: frames).screen.pixel(*OUT_OF_THE_TILE)

  def test_a_scene_shows_its_own_backdrop_and_the_next_the_games
    prog = ScreenBackdropGames.title_and_board(title_screen: { backdrop: SKY })

    assert_equal SKY, shown_by(prog, 3), "the title's own"
    assert_equal 0, shown_by(prog, 10), "the board says none, so the game's"
  end

  # Arriving under a fade, the new colour 0 is faded with the rest.
  def test_a_scene_arriving_under_a_fade_toward_white_fades_its_backdrop
    sky = SKY
    b = Builder.new
    b.instance_eval do
      screen :tiled
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, 0
      tick = 0
      faded = var :faded, 0
      scene(:board) { background :board, tiles: :corner_set, map: ["c"] }
      scene(:title) do
        screen(:tiled, backdrop: sky)
        background :title, tiles: :corner_set, map: ["c"]
      end
      game_loop do
        tick += 1
        faded = 50 if tick == 4
        faded = 0 if tick == 9
        fade :white, faded
        state = 1 if tick == 6
        case_var(:state) do
          when_val 0, :board
          when_val 1, :title
        end
      end
    end
    b.finalize_program

    refute_equal SKY, shown_by(b.program, 8), "the sky, moved toward white"
    assert_equal SKY, shown_by(b.program, 14), "and the sky itself once the fade is over"
  end
end
