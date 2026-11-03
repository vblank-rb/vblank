# frozen_string_literal: true

require "test_helper"
require "differential"

# THE LIGHT'S ROWS ARE WORKED OUT AT THE END OF A PASS, not in the gap between frames (see
# GBA::Raster#emit_stage_light_rows). A light that changes every frame and whose rows take longer
# than the gap to work out used to be worked out in the gap ahead of the sprites, so the sprites
# were written while the top of the screen was already being drawn from them. Two overlapping
# sprites at the very top that swap which is in front on every pass are what shows it: drawn
# from a half-written table, the screen shows the pass before's order.
class TestSpritesBeforeRowTables < Minitest::Test
  include Differential

  private def swapping_under_a_busy_light
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :set, "#" => :white_tile
      background :room, tiles: :set, map: ["#" * 32] * 32
      image(:red_box, "#" => :red) { (["#" * 16] * 16).join("\n") }
      image(:blue_box, "#" => :blue) { (["#" * 16] * 16).join("\n") }
      back = sprite :red_box, at: [180, -6]
      front = sprite :blue_box, at: [188, -2]
      draw_in_order(back, front)
      light = spotlight at: [120, 80], radius: 70, dark: 60
      # Forty steps a row that change nothing: rows that take longer than the gap to work out.
      light.shape do |row|
        spent = var :_spent, 0
        repeat(40) { spent += row }
        light.circle(row) + (spent & 0)
      end
      pass = var :pass, 0
      game_loop do
        pass += 1
        if (pass & 1) == 1
          back.y = -6
          front.y = -2
        else
          back.y = -2
          front.y = -6
        end
        light.move_to 100 + (pass & 15), 80
      end
    end
    b.finalize_program
    b.program
  end

  def test_sprites_at_the_top_swap_on_the_frame_they_are_told_under_a_busy_light
    assert_backends_agree(swapping_under_a_busy_light, frames: 6..12)
  end
end
