# frozen_string_literal: true

require "test_helper"
require "many_tiles"

# EACH SCREEN'S BACKGROUND TILES ARE ITS OWN TO COUNT. Video memory holds 1024 background tiles at
# once, and a Super Nintendo's own games load a screen's with the screen, so two screens of 600 each
# never meet.
class TestSceneBackgroundTilesOnTheSuperNintendo < Minitest::Test
  SWITCH_AT = 4

  private def two_scenes(&shown_by_every_screen)
    switch = SWITCH_AT
    b = Builder.new
    b.instance_eval do
      screen :tiled
      first = ManyTiles.declare(self, :one_set, 600, :red)
      second = ManyTiles.declare(self, :two_set, 600, :green, from: 600)
      instance_eval(&shown_by_every_screen) if shown_by_every_screen
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :one_set, map: first }
      scene(:two) { background :two, tiles: :two_set, map: second }
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

  # The checked run holds every pass to the interpreter's picture, so a wrong tile in either scene
  # fails at the pass it shows.
  def test_two_scenes_of_six_hundred_tiles_each_show_their_own
    game_player.run(two_scenes, frames: SWITCH_AT * 5)
    pass
  end

  # The second scene's ground walks between two areas, and a tile taking turns through pictures is
  # in both, kept with the scene's own tiles: walking into the other area brings that area's tiles
  # in, and the picture the game chose stays.
  def test_a_picture_chosen_stays_on_a_walking_background_of_a_scenes_own_tiles
    switch = SWITCH_AT
    b = Builder.new
    b.instance_eval do
      screen :tiled
      first = ManyTiles.declare(self, :one_set, 600, :red)
      ManyTiles.declare(self, :two_set, 600, :green, from: 600)
      colors :pond, %i[transparent red blue green]
      { red_tile: 1, blue_tile: 2, green_tile: 3 }.each do |name, place|
        image(name, width: 8, height: 8, colors: :pond, places: Array.new(64, place))
      end
      image(:filler, width: 8, height: 8, colors: :pond, places: Array.new(64) { |i| 1 + (i % 3) })
      water = tile_pictures :water, colors: :pond, tiles: { top: %i[red_tile blue_tile] }
      tiles :near, "w" => water[:top], "#" => :green_tile, "o" => :two_set_1
      tiles :far, "#" => :filler, "g" => :green_tile, "w" => water[:top], "o" => :two_set_2
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { background :one, tiles: :one_set, map: first }
      scene(:two) do
        ground = background(:ground, tiles: { near: :near, far: :far },
                                     map: { near: { pond: ["w#o"] }, far: { lake: ["#gw"] } })
        ground.show_map :lake if tick == switch + 4
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        water.show 1 if tick == switch + 2
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    b.finalize_program

    screen = game_player.run(b.program, frames: SWITCH_AT + 9).screen
    assert_equal 0x7C00, screen.pixel(20, 4), "the picture chosen, blue, in the area walked into"
  end

  def test_what_every_screen_shows_stays_in_video_memory
    program = two_scenes do
      layers :ground, :front
      image(:spot, "#" => :white) { "########\n" * 8 }
      tiles :spot_set, "#" => :spot
      layer(:front) { background :spots, tiles: :spot_set, map: Array.new(32) { "#" * 32 } }
    end

    assert_equal 0x7FFF, game_player.run(program, frames: SWITCH_AT * 5).screen.pixel(2, 2)
  end
end
