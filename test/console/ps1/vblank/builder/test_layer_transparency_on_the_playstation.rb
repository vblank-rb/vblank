# frozen_string_literal: true

require "test_helper"
require "see_through_scenery_tests"

# A SEE-THROUGH LAYER OF SCENERY on every run that plays games as the PlayStation. Its graphics chip mixes
# a layer with what is behind it in three ways that are shares of the two: half of each, all of each added,
# and a quarter of the layer added to all of what is behind (Console::PS1Hardware::SEMI_TRANSPARENCY_MODES).
# A layer at one of those amounts is drawn see-through; any other amount, or one the game works out as it
# runs, is refused while the game is built (Console::PS1Answers). Not in test/all/: the Advance mixes by
# any sixteenth, so an amount refused here plays there.
#
# The colours are picked so the chip's five-bit mix and the interpreter's own come to the same pixel, so
# the numbers below are the picture on every run that plays as the PlayStation. Where they would not, the
# PlayStation's run holds the picture to the chip's own mix (PS1::SemiTransparency).
#
# The tests of a layer half see-through under a fade or a tint, and in a scene of its own, that the
# Advance plays too are SeeThroughSceneryTests'.
class TestLayerTransparencyOnThePlayStation < Minitest::Test
  include SeeThroughSceneryTests

  # A grey of 8 over red: added whole, red stays 31 and the grey's 8 comes in; a quarter of it, 2.
  GREY_ADDED_TO_RED = 31 | (8 << 5) | (8 << 10)
  QUARTER_GREY_ADDED_TO_RED = 31 | (2 << 5) | (2 << 10)

  def test_a_layer_half_see_through_shows_half_of_each
    assert_equal HALF_WHITE_OVER_RED, pane_pixel(pane_program(transparency: 50))
    assert_equal HALF_WHITE_OVER_RED, pane_pixel(pane_program(shows: 50, shows_behind: 50))
  end

  def test_a_layer_added_to_what_is_behind_shows_all_of_each
    assert_equal GREY_ADDED_TO_RED, pane_pixel(pane_program(color: [8, 8, 8], shows: 100, shows_behind: 100))
  end

  def test_a_quarter_of_a_layer_added_to_what_is_behind
    assert_equal QUARTER_GREY_ADDED_TO_RED, pane_pixel(pane_program(color: [8, 8, 8], shows: 25, shows_behind: 100))
  end

  # The pane's see-through pixels show the floor as it is, a layer at nought is drawn whole, and one at a
  # hundred shows the floor alone.
  def test_what_the_layer_does_not_draw_shows_plain_and_the_ends_need_no_mix
    screen = game_player.run(pane_program(transparency: 50, gaps: true), frames: 2).screen

    assert_equal HALF_WHITE_OVER_RED, screen.pixel(0, 0), "the pane's pixel"
    assert_equal RED, screen.pixel(1, 0), "the floor, through the gap"
    assert_equal WHITE, pane_pixel(pane_program(transparency: 0)), "a solid pane"
    assert_equal RED, pane_pixel(pane_program(transparency: 100)), "a pane not seen"
  end

  # A scene's own see-through layer goes up on the plane another scene's solid background used.
  def test_a_scene_sees_through_its_own_layer_after_a_scene_that_sees_through_nothing
    assert_equal WHITE, pane_pixel(two_rooms_program, frames: 2), "the hall's solid wall"
    assert_equal HALF_WHITE_OVER_RED, pane_pixel(two_rooms_program, frames: 8), "the room's mist"
  end

  # Each room sees through a layer of its own by its own amount, from the frame it takes over.
  def test_each_room_is_seen_through_by_its_own_amount
    assert_equal HALF_WHITE_OVER_RED, pane_pixel(misty_and_glowing_rooms, frames: 2), "the misty room, half of each"
    assert_equal GREY_ADDED_TO_RED, pane_pixel(misty_and_glowing_rooms, frames: 8), "the glowing room, added"
    assert_equal HALF_WHITE_OVER_RED, pane_pixel(misty_and_glowing_rooms, frames: 14), "the misty room again"
  end

  def test_an_amount_the_chip_cannot_mix_is_refused
    error = assert_raises(VBlank::IR::Guardrails::ValidationError) { pane_pixel(pane_program(transparency: 40)) }

    assert_match(/transparency: 40/, error.message)
    assert_match(/PlayStation cannot mix/, error.message)
  end

  def test_an_amount_the_game_works_out_is_refused
    error = assert_raises(VBlank::IR::Guardrails::ValidationError) { pane_pixel(worked_out_program) }

    assert_match(/works out how see-through layer :glass is/, error.message)
  end

  private def pane_pixel(program, frames: 2) = game_player.run(program, frames: frames).screen.pixel(8, 8)

  # A red floor with a pane over it, the pane's layer see-through by +amounts+; with +gaps+, every other
  # pixel of the pane's tile is see-through.
  private def pane_program(color: [31, 31, 31], gaps: false, **amounts)
    tile = gaps ? "#.#.#.#.\n" * 8 : SOLID_TILE
    program do
      screen :tiled
      image(:back, "#" => :red) { SOLID_TILE }
      image(:front, "#" => rgb(*color), "." => :transparent) { tile }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(32) { "#" * 32 } }
      layer(:glass, **amounts) { background :pane, tiles: :frontset, map: Array.new(32) { "#" * 32 } }
      game_loop { wait_vblank }
    end
  end

  # A hall with a solid white wall over the red floor, then a room with white mist over it, half see-through.
  private def two_rooms_program
    program do
      screen :tiled
      image(:back, "#" => :red) { SOLID_TILE }
      image(:front, "#" => :white) { SOLID_TILE }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      layers :deep, :walls, :mist
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(32) { "#" * 32 } }
      scene(:hall) { layer(:walls) { background :wall, tiles: :frontset, map: Array.new(32) { "#" * 32 } } }
      scene(:room) { layer(:mist, transparency: 50) { background :fog, tiles: :frontset, map: Array.new(32) { "#" * 32 } } }
      state = var :state, 0
      tick = var :tick, 0
      game_loop do
        tick += 1
        state = 1 if tick > 4
        case_var(:state) do
          when_val 0, :hall
          when_val 1, :room
        end
      end
    end
  end

  # A misty room, white half see-through over red, and a glowing one, grey added to red, taking turns:
  # misty, glowing from the fifth pass, misty again from the eleventh.
  private def misty_and_glowing_rooms
    program do
      screen :tiled
      image(:back, "#" => :red) { SOLID_TILE }
      image(:white, "#" => :white) { SOLID_TILE }
      image(:grey, "#" => rgb(8, 8, 8)) { SOLID_TILE }
      tiles :backset, "#" => :back
      tiles :whites, "#" => :white
      tiles :greys, "#" => :grey
      full = Array.new(32) { "#" * 32 }
      layers :deep, :mist, :glow
      scene(:misty) do
        layer(:deep) { background :floor, tiles: :backset, map: full }
        layer(:mist, transparency: 50) { background :mist_pane, tiles: :whites, map: full }
      end
      scene(:glowing) do
        layer(:deep) { background :glow_floor, tiles: :backset, map: full }
        layer(:glow, shows: 100, shows_behind: 100) { background :glow_pane, tiles: :greys, map: full }
      end
      where = var :where, 0
      pass = var :pass, 0
      game_loop do
        pass += 1
        where = 1 if pass == 5
        where = 0 if pass == 11
        case_var(:where) do
          when_val 0, :misty
          when_val 1, :glowing
        end
      end
    end
  end

  # A pane that thickens as the game runs.
  private def worked_out_program
    program do
      screen :tiled
      image(:back, "#" => :red) { SOLID_TILE }
      image(:front, "#" => :white) { SOLID_TILE }
      tiles :backset, "#" => :back
      tiles :frontset, "#" => :front
      clear = var :clear, 100
      layers :deep, :glass
      layer(:deep) { background :floor, tiles: :backset, map: Array.new(32) { "#" * 32 } }
      layer(:glass, transparency: clear) { background :pane, tiles: :frontset, map: Array.new(32) { "#" * 32 } }
      game_loop { clear.approach! 0, 10 }
    end
  end
end
