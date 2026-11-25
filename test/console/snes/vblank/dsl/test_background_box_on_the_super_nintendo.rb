# frozen_string_literal: true

require "test_helper"
require "background_box_tests"

# A background shown only inside a box the game moves and sizes, on the Super Nintendo, whose
# display holds a layer to a window: the tests every console that can hold a layer to a box plays
# (BackgroundBoxTests in test/background_box_tests.rb). The Advance's twin is
# test/console/gba/vblank/dsl/test_background_box.rb.
class TestBackgroundBoxOnTheSuperNintendo < Minitest::Test
  include BackgroundBoxTests

  # The layer behind has a window of its own: the green layer held to a box sliding right and
  # growing past 127 rows, so its line table takes two steps for the box's lines, under a red layer
  # whose map fills only its top rows. Outside the box and below the red rows, the backdrop shows.
  def test_the_layer_behind_held_to_a_tall_box
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :sky_set, "#" => :green_tile
      tiles :box_set, "#" => :red_tile
      layers :back, :front
      sky = nil
      layer(:back) { sky = background :sky, tiles: :sky_set, map: Array.new(32) { "#" * 32 } }
      layer :front do
        background :dialogue, tiles: :box_set, map: Array.new(4) { "#" * 32 }
        passes = var :passes, 0
        game_loop do
          passes += 1
          sky.show_only_inside passes * 9, 20, 120, 100 + (passes * 20)
        end
      end
    end
    b.finalize_program

    assert_backends_agree(b.program, frames: [2, 5, 8], name: "TWOBOXES")
  end
end
