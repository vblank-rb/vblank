# frozen_string_literal: true

require "test_helper"

# Small games that fade under a layer in one scene and then change scene, shared with the
# cartridge's test in test/lowering/gba/vblank/builder/test_placed_fade_across_scenes_cartridge.rb.
module PlacedFadeAcrossScenesGames
  # The turn of the game's loop the title hands over to the room on.
  CHANGES_ON = 6

  # Frames to read: in the title, the pass that changes scene, the three after it, and well after.
  IN_TITLE = 3
  AROUND_THE_CHANGE = [IN_TITLE, CHANGES_ON, CHANGES_ON + 1, CHANGES_ON + 2, CHANGES_ON + 6, CHANGES_ON + 10].freeze
  SETTLED = CHANGES_ON + 6

  # A white room every scene shows. The title puts a red pond over its top left corner, in front
  # of the room, and runs +title+: by default a fade half way to black under the pond's layer, so
  # the room fades and the pond does not. From turn CHANGES_ON the scene is :playing, which runs
  # +playing+ (handed the turn) and by default nothing at all.
  #
  # +with_sprite+ adds a green sprite to the room's layer that every scene shows, +back_on+ is the
  # turn the title takes over again, and +stack+ names the layers back to front.
  def faded_title_then_room(with_sprite: false, back_on: nil, stack: %i[ground water], title: nil, playing: nil)
    title ||= proc { fade :black, 50, under: :water }
    playing ||= proc {}
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      layers(*stack)
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:blue_tile, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile, "r" => :red_tile, "b" => :blue_tile
      layer(:ground) { background :room, tiles: :set, map: ["#" * 32] * 32 }
      layer(:ground) { sprite :guy, at: [200, 20] } if with_sprite
      mode = var :mode, 0
      turn = var :turn, 0
      scene(:title) do
        layer(:water) { background :pond, tiles: :set, map: ["r" * 4] * 4 }
        instance_exec(&title)
      end
      scene(:playing) { instance_exec(turn, &playing) }
      game_loop do
        turn += 1
        mode.store!(1) if turn == CHANGES_ON
        mode.store!(0) if back_on && turn == back_on
        case_var(:mode) { when_val 0, :title; when_val 1, :playing }
      end
    end
    builder.finalize_program
    builder.program
  end

  # The room fades under another amount in the second scene.
  def room_fading_less = faded_title_then_room(playing: proc { fade :black, 25, under: :water })

  # The second scene takes the fade off, with a fade of nothing, three turns after it takes over.
  def room_lifting_the_fade = faded_title_then_room(playing: proc { |turn| fade :black, 0 if turn == CHANGES_ON + 3 })

  # ...and with `fade_in`, over four frames.
  def room_fading_in = faded_title_then_room(playing: proc { |turn| fade_in frames: 4 if turn == CHANGES_ON + 3 })

  # The second scene is painted, a green screen, where the title's is drawn from tiles.
  def painted_room = faded_title_then_room(playing: proc { screen :bitmap; clear_screen :green })

  # The title fades the whole screen, or tints it, and no layer is named.
  def title_fading_everything = faded_title_then_room(title: proc { fade :black, 50 })
  def title_tinting_everything = faded_title_then_room(title: proc { tint :blue, 50 })

  # The second scene puts blue mist over the top left corner, in a layer in front of the pond's
  # that shows half of itself and half of what is behind it.
  def room_with_mist(with_sprite: false)
    faded_title_then_room(with_sprite: with_sprite, stack: %i[ground water mist], playing: proc {
      layer(:mist, shows: 50, shows_behind: 50) { background :fog, tiles: :set, map: ["b" * 4] * 4 }
    })
  end
end

# A FADE PLACED IN THE STACK IS THE GAME'S, AND STAYS UNTIL THE GAME LIFTS IT. A scene that takes
# over says nothing about the fade, so what it shows is faded as the scene before left it: its
# own scenery, what every scene shows and the backdrop. A game fades out, changes scene and fades
# in on that rule.
class TestPlacedFadeAcrossScenesOnTheAdvance < Minitest::Test
  include PlacedFadeAcrossScenesGames

  WHITE = Color.resolve(:white)
  RED = Color.resolve(:red)
  BLUE = Color.resolve(:blue)
  GREEN = Color.resolve(:green)
  ROOM = [120, 80].freeze    # the room, clear of the pond and the sprite
  CORNER = [10, 10].freeze   # under the title's pond and the second scene's mist
  SPRITE = [203, 23].freeze

  private def shown(program, frames:) = game_player.run(program, frames: frames).screen

  # The colour the room is faded to in the title.
  private def faded_room(program)
    color = shown(program, frames: IN_TITLE).pixel(*ROOM)
    refute_equal WHITE, color, "the title fades the room"
    color
  end

  def test_the_title_fades_the_room_and_keeps_its_pond
    screen = shown(faded_title_then_room, frames: IN_TITLE)

    refute_equal WHITE, screen.pixel(*ROOM)
    assert_equal RED, screen.pixel(*CORNER), "the pond is in the layer the fade is under"
  end

  def test_the_room_stays_faded_when_a_scene_with_no_sprite_takes_over
    game = faded_title_then_room
    faded = faded_room(game)

    [CHANGES_ON, CHANGES_ON + 1, SETTLED].each do |frames|
      screen = shown(game, frames: frames)

      assert_equal faded, screen.pixel(*ROOM), "the room on frame #{frames}"
      assert_equal faded, screen.pixel(*CORNER), "where the pond was, on frame #{frames}"
    end
  end

  def test_the_room_and_a_sprite_in_its_layer_stay_faded_when_a_scene_takes_over
    game = faded_title_then_room(with_sprite: true)
    faded = faded_room(game)
    faded_sprite = shown(game, frames: IN_TITLE).pixel(*SPRITE)
    screen = shown(game, frames: SETTLED)

    refute_equal GREEN, faded_sprite, "the fade reaches a sprite in the room's layer"
    assert_equal faded, screen.pixel(*ROOM)
    assert_equal faded_sprite, screen.pixel(*SPRITE)
  end

  def test_a_scene_that_fades_another_amount_shows_its_own
    game = room_fading_less
    screen = shown(game, frames: SETTLED)

    refute_equal WHITE, screen.pixel(*ROOM)
    refute_equal faded_room(game), screen.pixel(*ROOM), "the second scene's fade took the first one's place"
  end

  def test_the_title_given_the_screen_back_shows_its_pond_over_the_faded_room
    game = faded_title_then_room(back_on: CHANGES_ON + 4)
    faded = faded_room(game)
    screen = shown(game, frames: CHANGES_ON + 8)

    assert_equal faded, shown(game, frames: CHANGES_ON + 2).pixel(*CORNER), "faded room where the pond was"
    assert_equal faded, screen.pixel(*ROOM)
    assert_equal RED, screen.pixel(*CORNER)
  end

  def test_a_fade_of_nothing_in_the_second_scene_lifts_it
    game = room_lifting_the_fade

    assert_equal faded_room(game), shown(game, frames: CHANGES_ON + 2).pixel(*ROOM), "still faded before the lift"
    assert_equal WHITE, shown(game, frames: SETTLED).pixel(*ROOM)
  end

  def test_fade_in_in_the_second_scene_lifts_it
    game = room_fading_in

    assert_equal faded_room(game), shown(game, frames: CHANGES_ON + 2).pixel(*ROOM), "still faded before the fade in"
    assert_equal WHITE, shown(game, frames: CHANGES_ON + 10).pixel(*ROOM)
  end

  # A fade over the whole screen and a tint stay the same way, the pond's place included.
  def test_a_whole_screen_fade_and_a_tint_stay_when_a_scene_takes_over
    [title_fading_everything, title_tinting_everything].each do |game|
      faded = faded_room(game)
      screen = shown(game, frames: SETTLED)

      assert_equal faded, screen.pixel(*ROOM)
      assert_equal faded, screen.pixel(*CORNER)
    end
  end

  # A PAINTED SCREEN HAS NO LAYERS for a fade to fall between, so a painted scene that takes over
  # shows as it was painted.
  def test_a_painted_scene_that_takes_over_shows_as_painted
    screen = shown(painted_room, frames: SETTLED)

    assert_equal GREEN, screen.pixel(*ROOM)
    assert_equal GREEN, screen.pixel(*CORNER)
  end

  # THE DISPLAY MIXES ONE THING AT A TIME, and a fade placed in the stack holds that until it is
  # lifted. So a see-through layer the second scene brings is solid over the faded room.
  def test_a_see_through_layer_the_second_scene_brings_is_solid_while_the_fade_stays
    [room_with_mist, room_with_mist(with_sprite: true)].each do |game|
      screen = shown(game, frames: SETTLED)

      assert_equal faded_room(game), screen.pixel(*ROOM)
      assert_equal BLUE, screen.pixel(*CORNER), "the mist is in front of the fade's layer, and solid"
    end
  end
end
