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

  private def two_scenes(shared: false)
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
  def test_two_scenes_of_three_hundred_tiles_each_show_their_own
    game_player.run(two_scenes, frames: SWITCH_AT * 5)
    pass
  end

  def test_a_picture_both_scenes_show_stays_in_video_memory
    screen = game_player.run(two_scenes(shared: true), frames: SWITCH_AT * 5).screen

    assert_equal 0x7FFF, screen.pixel(102, 102)
  end
end
