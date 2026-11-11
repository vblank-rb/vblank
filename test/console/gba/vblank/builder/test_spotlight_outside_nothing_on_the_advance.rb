# frozen_string_literal: true

require "test_helper"
require "differential"

# Small games whose light shows nothing outside it (`spotlight outside: :nothing`) over a
# see-through layer, shared with the cartridge's test in
# test/lowering/gba/vblank/builder/test_spotlight_outside_nothing_cartridge.rb.
module SpotlightOutsideNothingGames
  # The turns of the game's loop the circle starts to close and to open on.
  CLOSES_ON = 3
  OPENS_ON = 14

  # Frames to read: before the circle, while it closes, shut, while it opens, and open again.
  BEFORE = 2
  CLOSING = 6
  SHUT = 12
  OPENING = 17
  OPEN = 26

  # A white room under a red layer that shows half of itself and half of the room, the whole
  # screen over. The circle closes on the middle from turn CLOSES_ON, 60 pixels and 10 fewer
  # every turn, and opens again from turn OPENS_ON. +screen_options+ are the screen's, and
  # +said+ is run before the loop.
  def clouds_under_a_closing_circle(light: { outside: :nothing }, **screen_options, &said)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled, **screen_options
      layers :ground, :clouds
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile, "r" => :red_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      layer(:clouds, shows: 50, shows_behind: 50) { background :sky, tiles: :set, map: ["r" * 32] * 32 }
      spotlight(**light)
      turn = var :turn, 0
      instance_exec(&said) if said
      game_loop do
        turn += 1
        iris_out at: [120, 80], from: 60, by: 10 if turn == CLOSES_ON
        iris_in by: 10, to: 60, dark: 0 if turn == OPENS_ON
      end
    end
    builder.finalize_program
    builder.program
  end
end

# A LIGHT THAT SHOWS NOTHING OUTSIDE IT, where a light otherwise darkens what is there.
#
# The console's circle is its first window and nothing more: inside it every layer is drawn and
# mixed as the game set them, and outside it no layer is drawn at all, so the screen's backdrop
# colour shows. The part of the display that mixes the picture is never asked for, which is what
# lets a see-through layer go on mixing inside the circle while it closes.
class TestSpotlightOutsideNothingOnTheAdvance < Minitest::Test
  include Differential
  include SpotlightOutsideNothingGames

  WHITE = Color.resolve(:white)
  RED = Color.resolve(:red)
  BLACK = Color.rgb(0, 0, 0)
  MIDDLE = [120, 80].freeze
  CORNER = [5, 5].freeze

  private def shown(program, frames:) = game_player.run(program, frames: frames).screen

  # The colour the red layer and the white room mix to, read where no circle is in the way.
  private def mixed(program = clouds_under_a_closing_circle)
    color = shown(program, frames: BEFORE).pixel(*CORNER)
    refute_includes [WHITE, RED, BLACK], color, "the layer is mixed with the room"
    color
  end

  def test_the_layer_is_mixed_everywhere_before_the_circle_closes
    screen = shown(clouds_under_a_closing_circle, frames: BEFORE)

    assert_equal mixed, screen.pixel(*MIDDLE)
    assert_equal mixed, screen.pixel(*CORNER)
  end

  def test_a_closing_circle_shows_the_mixed_layer_inside_and_nothing_outside
    screen = shown(clouds_under_a_closing_circle, frames: CLOSING)

    assert_equal mixed, screen.pixel(*MIDDLE), "inside the circle the layer goes on mixing"
    assert_equal BLACK, screen.pixel(*CORNER), "outside it nothing is drawn"
    assert_equal BLACK, screen.pixel(120, 150), "seventy below the middle is outside too"
  end

  def test_a_shut_circle_shows_nothing_anywhere
    screen = shown(clouds_under_a_closing_circle, frames: SHUT)

    assert_equal BLACK, screen.pixel(*MIDDLE)
    assert_equal BLACK, screen.pixel(*CORNER)
  end

  def test_an_opening_circle_shows_the_mixed_layer_inside_and_nothing_outside
    screen = shown(clouds_under_a_closing_circle, frames: OPENING)

    assert_equal mixed, screen.pixel(*MIDDLE)
    assert_equal BLACK, screen.pixel(*CORNER)
  end

  def test_the_whole_mixed_picture_is_back_once_the_circle_has_opened
    screen = shown(clouds_under_a_closing_circle, frames: OPEN)

    assert_equal mixed, screen.pixel(*MIDDLE)
    assert_equal mixed, screen.pixel(*CORNER)
  end

  def test_the_console_draws_the_same_picture_on_every_one_of_those_frames
    assert_backends_agree(clouds_under_a_closing_circle, frames: [BEFORE, CLOSING, SHUT, OPENING, OPEN], name: "SHUTOUT")
  end

  # NOTHING IS THE SCREEN'S BACKDROP COLOUR, which is black unless the game set one: the colour
  # the screen shows wherever no layer draws.
  def test_outside_the_circle_is_the_backdrop_the_screen_was_given
    sky = clouds_under_a_closing_circle(backdrop: :blue)
    screen = shown(sky, frames: CLOSING)

    assert_equal Color.resolve(:blue), screen.pixel(*CORNER)
    assert_equal mixed(sky), screen.pixel(*MIDDLE)
    assert_backends_agree(sky, frames: [CLOSING, SHUT], name: "BLUEOUT")
  end

  # A fade reaches the whole picture, the backdrop outside the circle with it.
  def test_a_fade_reaches_the_backdrop_outside_the_circle
    faded = clouds_under_a_closing_circle(backdrop: :blue) { fade :black, 50 }
    screen = shown(faded, frames: CLOSING)

    refute_equal Color.resolve(:blue), screen.pixel(*CORNER)
    refute_equal BLACK, screen.pixel(*CORNER)
    assert_backends_agree(faded, frames: [BEFORE, CLOSING, SHUT], name: "FADEOUT")
  end

  # A light declared where it stands shows nothing outside it from the first picture, and is
  # switched off by a darkness of nothing.
  def test_a_light_declared_with_a_place_shows_nothing_outside_it_at_once
    lantern = clouds_under_a_closing_circle(light: { at: [120, 80], radius: 30, outside: :nothing })
    screen = shown(lantern, frames: BEFORE)

    assert_equal mixed, screen.pixel(*MIDDLE)
    assert_equal BLACK, screen.pixel(*CORNER)
    assert_backends_agree(lantern, frames: BEFORE, name: "LANTERN")
  end

  def test_a_darkness_of_nothing_switches_the_light_off
    off = clouds_under_a_closing_circle(light: { at: [120, 80], radius: 30, dark: 0, outside: :nothing })

    assert_equal mixed, shown(off, frames: BEFORE).pixel(*CORNER)
  end

  # --- taking turns with a fade placed in the stack ---

  # A title half faded under its front layer, then from turn 6 a scene whose light shows nothing
  # outside it. +with_sprite+ adds a green sprite in the room's layer, inside the light.
  private def faded_title_then_light(with_sprite: false)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      layers :ground, :water
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile, "r" => :red_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      layer(:ground) { sprite :guy, at: [100, 76] } if with_sprite
      mode = var :mode, 0
      turn = var :turn, 0
      spotlight at: [120, 80], radius: 40, outside: :nothing
      scene(:title) do
        layer(:water) { background :pond, tiles: :set, map: ["r" * 4] * 4 }
        fade :black, 50, under: :water
      end
      scene(:playing) {}
      game_loop do
        turn += 1
        mode = 1 if turn == 6
        case_var(:mode) { when_val 0, :title; when_val 1, :playing }
      end
    end
    builder.finalize_program
    builder.program
  end

  # A FADE PLACED IN THE STACK STILL TAKES TURNS WITH THE LIGHT, scene by scene: the light is off
  # while the title fades under its layer, and on in the next scene.
  def test_the_light_is_off_in_a_scene_that_fades_under_a_layer
    title = shown(faded_title_then_light, frames: 3)
    playing = shown(faded_title_then_light, frames: 12)

    assert_equal title.pixel(*MIDDLE), title.pixel(200, 150), "the title's room is faded the same everywhere"
    refute_equal BLACK, title.pixel(200, 150)
    assert_equal WHITE, playing.pixel(*MIDDLE)
    assert_equal BLACK, playing.pixel(*CORNER)
    assert_backends_agree(faded_title_then_light, frames: [3, 6, 7, 8, 12], name: "FADETURN")
  end

  # THE LIT SCENE TAKES THE FADE OFF. A fade placed in the stack stays across a change of scene
  # until the game lifts it, but not into a scene the light is on in: the two take turns, since
  # the light's shape takes the place of the one that keeps a sprite out of such a fade. So the
  # room and a sprite in its layer, faded in the title, are as drawn inside the light, on the
  # pass the lit scene takes over and after.
  def test_a_lit_scene_takes_the_fade_of_the_scene_before_off
    game = faded_title_then_light(with_sprite: true)
    title = shown(game, frames: 3)
    changing = shown(game, frames: 6)
    playing = shown(game, frames: 12)

    refute_equal WHITE, title.pixel(*MIDDLE), "the title fades the room"
    refute_equal Color.resolve(:green), title.pixel(103, 79), "...and the sprite in its layer"
    assert_equal WHITE, changing.pixel(*MIDDLE), "the fade is off on the pass the lit scene takes over"
    assert_equal WHITE, changing.pixel(*CORNER), "...a picture before the light is on"
    assert_equal WHITE, playing.pixel(*MIDDLE)
    assert_equal Color.resolve(:green), playing.pixel(103, 79)
    assert_equal BLACK, playing.pixel(*CORNER)
    assert_backends_agree(game, frames: [3, 6, 7, 8, 12], name: "FADETURNGUY")
  end
end
