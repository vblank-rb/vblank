# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/builder/test_layer_transparency"

# A SEE-THROUGH LAYER OF SCENERY, solid, not seen and half see-through, under a fade or a tint that
# walks the colours, and in a scene that takes over from one seeing through nothing: the tests every
# console that mixes a layer of backgrounds by half plays, the Advance (test/console/gba/vblank/builder/
# test_layer_transparency_on_the_advance.rb) and the PlayStation (test/console/ps1/vblank/builder/
# test_layer_transparency_on_the_playstation.rb). The games are LayerTransparencyGames'.
module SeeThroughSceneryTests
  include Differential
  include LayerTransparencyGames

  def test_a_see_through_layer_of_scenery_shows_what_is_behind_it
    seen = [0, 50, 100].map { |amount| shown(scenery_program(amount), *SCENERY_XY) }

    assert_equal [WHITE, HALF_WHITE_OVER_RED, RED], seen
  end

  # FADING TO WHITE IS THE OTHER DIRECTION AND NOT A MIRROR OF THE FIRST. Toward white a
  # channel adds a share of the headroom it has left; toward black it keeps a share of
  # what it has, and the two truncate opposite ways — so one direction can be right while
  # the other is a step out at every pixel. Both halves of the picture are asserted: the
  # layer is still blending, and the two backends land on the same color.
  def test_a_fade_to_white_leaves_the_layer_see_through_too
    solid = shown(faded_program(:scenery, 0, 25, toward: :white), *SCENERY_XY)

    refute_equal solid, shown(faded_program(:scenery, 50, 25, toward: :white), *SCENERY_XY),
                 "the see-through layer went solid while a fade to white ran"
  end

  # A TINT does not take the blend. On a tiled screen a tint moves the colors themselves
  # rather than asking the display to blend, so the layer keeps seeing through them: a
  # `flash_screen :red` reaches a game the water can be seen through and a white one does
  # not. What shows is the layer blending TINTED colors, so it is neither the plain
  # see-through value nor the solid one.
  def test_a_tint_leaves_the_layer_see_through
    solid = shown(tinted_program(0, 50), *SCENERY_XY)

    refute_equal solid, shown(tinted_program(50, 50), *SCENERY_XY),
                 "a tint took the layer's blend away"
  end

  # --- a see-through layer in a game that has SCENES ---
  #
  # Scenes take turns with the console's layers, so which layer a background sits on depends on
  # which scene it was declared in, and a scene that sees through nothing must not mix whatever
  # background inherited the see-through one's place (LayerTransparencyGames#scenes_that_take_turns).
  def test_a_scene_sees_through_its_own_layer
    assert_equal HALF_WHITE_OVER_RED,
                 shown(scenes_that_take_turns, *SCENERY_XY, frames: SWITCH_AT + 4),
                 "the scene's pane does not show the floor under it"
  end

  def test_the_two_backends_draw_the_same_screen_when_a_scene_sees_through_a_layer
    assert_backends_agree(scenes_that_take_turns, frames: SWITCH_AT + 4)
  end

  # ...and the scene BEFORE it, which sees through nothing, must not have picked up the
  # blend. Its two backgrounds sit on the layers the dive's floor and pane later use, so a
  # blend set up once at boot would quietly make the banner see-through.
  def test_a_scene_that_sees_through_nothing_is_drawn_solid
    green = VBlank::Graphics::Color.resolve(:green)

    assert_equal green, shown(scenes_that_take_turns, *SCENERY_XY, frames: 2),
                 "the banner scene is blended on the oracle"
  end
end
