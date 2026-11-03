# frozen_string_literal: true

require "test_helper"
require "screen_backdrop_games"

# A BACKDROP THAT FOLLOWS A LIST, ACROSS A CHANGE OF SCREEN KIND only the Advance has: a scene on
# `screen :rotozoom` beside scenes on `screen :tiled`. Changing kind sends the background colours
# again, and the backdrop must still be the list's colour afterwards, not the one it was declared
# with. The backdrop itself is test/all/vblank/builder/test_screen_backdrop_list.rb.
class TestScreenBackdropListOnTheAdvance < Minitest::Test
  include VBlank::Testing::Pictures

  BLUE = VBlank::Graphics::Color.rgb(0, 0, 31)

  # A tiled title, a turning scene from pass 4, and a tiled board again from pass 8 if +back+; the
  # list is told to hold blue on pass 2 and never again. The title and the turning scene show the
  # corner tile, whose left half is see-through, in their top left cell; the board shows nothing.
  private def recolored_then_turned(back:)
    b = Builder.new
    b.instance_eval do
      colors :screen_colors, %i[black black]
      colors :lit, [BLUE, :white]
      screen :tiled, backdrop: :screen_colors
      ScreenBackdropGames.declare_corner_tile(self)
      state = var :state, 0
      tick = 0
      scene(:title) { background :title, tiles: :corner_set, map: ["c"] }
      scene(:turn) do
        screen :rotozoom
        background(:turner, tiles: :corner_set, map: Array.new(16) { "c" * 16 }).scale(1.0)
      end
      scene(:board) { screen :tiled } # nothing but the backdrop: no colours of its own to send
      game_loop do
        tick += 1
        recolor :screen_colors, :lit if tick >= 2
        state = 1 if tick == 4
        state = 2 if back && tick == 8
        case_var(:state) do
          when_val 0, :title
          when_val 1, :turn
          when_val 2, :board
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_turning_scene_keeps_the_backdrop_the_list_holds
    screen = game_player.run(recolored_then_turned(back: false), frames: 7).screen

    assert_equal shown(BLUE), screen.pixel(1, 1), "a see-through pixel"
    # The picture holds still from the turn on, so the console is read a little later, past the
    # frames its change of screen kind takes to start.
    assert_backends_agree(recolored_then_turned(back: false), frames: 7, console_frames: 9, name: "BDTURN")
  end

  def test_a_tiled_scene_after_a_turning_one_keeps_the_backdrop_the_list_holds
    screen = game_player.run(recolored_then_turned(back: true), frames: 11).screen

    assert_equal shown(BLUE), screen.pixel(100, 100), "an empty cell"
    assert_backends_agree(recolored_then_turned(back: true), frames: 11, console_frames: 13, name: "BDBACK")
  end
end
