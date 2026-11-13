# frozen_string_literal: true

require "test_helper"
require "sprite_layer_choice_tests"

# A sprite that changes which layer it is in, between two backgrounds DOS shows at once: the room every such
# console plays (SpriteLayerChoiceTests), the DOS build checked against the interpreter on every pass.
class TestSpriteLayerChoiceOnDOS < Minitest::Test
  include SpriteLayerChoiceTests

  # The hero goes upstairs, to the ground floor, to the stairs and back, a layer each pass, while a foe on the
  # ground floor walks across him: on some passes he is behind the foe he was placed before, and the sprites
  # drawn are counted back to front, as the interpreter counts them.
  def test_a_hero_changing_layer_each_pass_passes_behind_and_in_front_of_a_foe
    game_player.run(program do
      screen :tiled
      image(:floor, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:arch, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:guy, "#" => :red) { (["#" * 16] * 8).join("\n") }
      image(:foe, "#" => :green) { (["#" * 16] * 8).join("\n") }
      tiles :floors, "#" => :floor
      tiles :arches, "#" => :arch
      layers :stairs, :ground, :walking, :scenery, :upper
      layer(:ground) { background :ground_bg, tiles: :floors, map: (0...20).map { "#" * 30 } }
      layer(:scenery) { background :arch_bg, tiles: :arches, map: (0...20).map { ("#" * 13) + (" " * 17) } }
      hero = layer(:upper) { sprite :guy, at: [96, 64] }
      foe = layer(:walking) { sprite :foe, at: [104, 66] }
      depth = var :floor, 0
      step = var :step, 0
      game_loop do
        hero.put_in_layer %i[upper walking stairs], showing: depth
        step += 1
        depth = step % 4
        foe.move_to(step + 90, 66)
      end
    end, frames: 12)
  end
end
