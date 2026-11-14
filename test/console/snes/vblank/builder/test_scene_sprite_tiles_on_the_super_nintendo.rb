# frozen_string_literal: true

require "test_helper"

# EACH SCREEN'S SPRITE TILES ARE ITS OWN TO COUNT. Video memory holds 512 sprite tiles at once, and a
# Super Nintendo's own games load a screen's with the screen, so two screens of 300 each never meet.
class TestSceneSpriteTilesOnTheSuperNintendo < Minitest::Test
  SWITCH_AT = 4

  # Three pictures of a hundred tiles found nowhere else, numbered from +first+, and their names.
  def self.declare_pictures(builder, prefix, first)
    Array.new(3) do |which|
      pieces = Array.new(100) do |at|
        number = first + (which * 100) + at
        [(at % 10) * 8, (at / 10) * 8, Array.new(64) { |pixel| 1 + ((number >> (pixel % 11)) & 1) }]
      end
      name = :"#{prefix}_#{which}"
      builder.image(name, colors: %i[transparent red blue], pieces: pieces)
      name
    end
  end

  private def two_scenes(shared: false, dispatch_inside_test: false)
    switch = SWITCH_AT
    test = self.class
    b = Builder.new
    b.instance_eval do
      screen :tiled
      first = test.declare_pictures(self, :one, 1)
      second = test.declare_pictures(self, :two, 301)
      image(:both, "#" => :white) { "########\n" * 8 } if shared
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) do
        sprite first.first, at: [0, 0], frames: first, rate: 2
        sprite :both, at: [100, 100] if shared
      end
      scene(:two) do
        sprite second.first, at: [0, 0], frames: second, rate: 2
        sprite :both, at: [100, 100] if shared
      end
      game_loop do
        tick += 1
        state = 1 if tick == switch
        state = 0 if tick == switch * 3
        dispatch = lambda do
          case_var(:state) do
            when_val 0, :one
            when_val 1, :two
          end
        end
        if dispatch_inside_test
          dispatch.call if tick >= 0
        else
          dispatch.call
        end
      end
    end
    b.finalize_program
    b.program
  end

  # A DISPATCH INSIDE A TEST notes the scene number as the pass starts (IR::Frames), so the frame
  # that hands over shows the arriving scene's background with the leaving scene's sprite, in the
  # leaving scene's own tiles.
  def test_a_dispatch_inside_a_test_shows_the_leaving_sprite_in_its_own_tiles
    game_player.run(two_scenes(dispatch_inside_test: true), frames: SWITCH_AT * 5)
    pass
  end

  # The checked run holds every pass to the interpreter's picture, so a wrong tile in either scene
  # fails at the pass it shows.
  def test_two_scenes_of_three_hundred_tiles_each_show_their_own
    game_player.run(two_scenes, frames: SWITCH_AT * 5)
    pass
  end

  # The scene the game opens on has its tiles from power-on, so its first pass has nothing to load
  # and a game's frames count from where they would.
  def test_the_opening_scene_loads_nothing_on_its_first_pass
    test = self.class
    b = Builder.new
    b.instance_eval do
      screen :tiled
      first = test.declare_pictures(self, :one, 1)
      second = test.declare_pictures(self, :two, 301)
      opened = var :opened, -1
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { sprite first.first, at: [0, 0], frames: first, rate: 2 }
      scene(:two) { sprite second.first, at: [0, 0], frames: second, rate: 2 }
      game_loop do
        tick += 1
        opened = frames_since_power_on if tick == 2
        state = 1 if tick == 5
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
    b.finalize_program

    game_player.run(b.program, frames: 8)
    pass
  end

  def test_a_picture_both_scenes_show_stays_in_video_memory
    screen = game_player.run(two_scenes(shared: true), frames: SWITCH_AT * 5).screen

    assert_equal 0x7FFF, screen.pixel(102, 102)
  end
end
