# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# EACH SCREEN'S TILES ARE ITS OWN TO COUNT. Video memory holds 1471 tiles at once on a Genesis, and the
# console's own games load a screen's art as the screen starts, so two screens of 800 each never meet.
# The tiles every screen shows stay in video memory throughout; each scene's own go in as it takes over.
class TestSceneTilesOnTheGenesis < Minitest::Test
  SWITCH_AT = 4

  # The tiles of each scene's own background, more than half of what video memory holds.
  EACH_SCENE = 800

  # Where a scene's second tile is drawn: its first pixel is its number's lowest bit, which is set in
  # the second tile of each scene, red in the first scene's and green in the second's.
  SECOND_TILE = [8, 0].freeze

  # Where each scene's own sprite stands.
  MARK_AT = [160, 120].freeze

  # +loads_first+ gives each scene's hand-over a pass of its own (`scene ..., loads_first: true`).
  private def two_scenes(loads_first: false)
    switch = SWITCH_AT
    count = EACH_SCENE
    mark = MARK_AT
    b = Builder.new
    b.instance_eval do
      screen :tiled
      first = ManyTiles.declare(self, :one_set, count, :red)
      second = ManyTiles.declare(self, :two_set, count, :green, from: count)
      image(:dot, "#" => :white) { "########\n" * 8 }
      image(:one_mark, "#" => :yellow, "." => :red) { "####....\n" * 8 }
      image(:two_mark, "#" => :blue, "." => :green) { "....####\n" * 8 }
      sprite :dot, at: [300, 200]
      state = var :state, 0
      tick = var :tick, 0
      scene(:one, loads_first: loads_first) do
        background :one, tiles: :one_set, map: first
        sprite :one_mark, at: mark
      end
      scene(:two, loads_first: loads_first) do
        background :two, tiles: :two_set, map: second
        sprite :two_mark, at: mark
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def shown(color) = VBlank::Testing.shown(color)

  # The checked run holds every pass to the interpreter's picture, so a wrong tile in either scene
  # fails at the pass it shows.
  def test_two_scenes_of_eight_hundred_tiles_each_show_their_own
    game_player.run(two_scenes, frames: SWITCH_AT * 5)
    pass
  end

  # A scene that loads first takes its tiles in on the pass of its own it is given.
  def test_scenes_that_load_first_show_their_own
    game_player.run(two_scenes(loads_first: true), frames: SWITCH_AT * 5)
    pass
  end

  # THE PASS A SCENE TAKES OVER ON shows the new scene's map drawn from its own tiles, never from the
  # tiles of the scene before at the same places in video memory.
  def test_the_pass_of_the_hand_over_shows_the_new_scenes_own_tiles
    program = two_scenes

    assert_equal shown(:red), game_player.run(program, frames: SWITCH_AT - 1).screen.pixel(*SECOND_TILE), "the first scene"
    assert_equal shown(:green), game_player.run(program, frames: SWITCH_AT).screen.pixel(*SECOND_TILE), "the hand-over"
    assert_equal shown(:red), game_player.run(program, frames: SWITCH_AT * 3).screen.pixel(*SECOND_TILE), "and back"
  end

  def test_each_scenes_sprite_is_drawn_from_its_own_tiles
    program = two_scenes
    x, y = MARK_AT

    assert_equal shown(:yellow), game_player.run(program, frames: 2).screen.pixel(x, y), "the first scene's"
    assert_equal shown(:green), game_player.run(program, frames: SWITCH_AT + 2).screen.pixel(x, y), "the second's"
    assert_equal shown(:white), game_player.run(program, frames: SWITCH_AT + 2).screen.pixel(300, 200), "every screen's"
  end
end
