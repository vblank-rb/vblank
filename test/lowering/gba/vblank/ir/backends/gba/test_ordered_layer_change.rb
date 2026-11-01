# frozen_string_literal: true

require "test_helper"
require "differential"

# A sprite in a draw_in_order that changes layer, on the cartridge, where each sprite's depth is a
# number in its row of the sprite table and the order is which row it has.
class TestOrderedLayerChange < Minitest::Test
  include Differential

  def test_the_cartridge_shows_the_order_in_each_layer_as_the_interpreter_does
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:field, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:red, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:green, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :field
      layers :behind, :ground, :front
      layer(:ground) { background :world, tiles: :set, map: "###\n###\n###" }
      hero = layer(:front) { sprite :red, at: [4, 4] }
      guard = layer(:front) { sprite :green, at: [4, 8] }
      draw_in_order hero, guard
      step = 0
      behind = var :behind, 0
      game_loop do
        step += 1
        hero.move_to 4, 12 if step == 10
        behind = 1 if step == 20
        hero.put_in_layer %i[front behind], showing: behind
      end
    end
    b.finalize_program

    assert_backends_agree(b.program, frames: [6, 16, 28], name: "ORDERLAY")
  end
end
