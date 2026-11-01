# frozen_string_literal: true

require "test_helper"

# A PASS THAT CHANGES MANY CELLS OF A BACKGROUND has them all written in the blank after it, so the
# game never waits for the display, and the blank has to hold them beside everything else it does:
# video memory takes no write once the display reads it again, so a cell the blank did not reach
# would simply be lost, and the interpreter's picture, held on every pass, would show it.
class TestGBCCellsInTheBlank < Minitest::Test
  GBC = VBlank::IR::Backends::GBC

  def test_the_blank_holds_as_many_cells_as_a_pass_keeps_beside_every_sprite_moving
    kept = GBC::Runtime::Picture::CELLS_KEPT

    GBC::CheckedRun.new.run(cells_game(kept), frames: 12)
    pass
  end

  private def cells_game(cells)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { "########\n" * 8 }
      image(:blue_art, "#" => :blue) { "########\n" * 8 }
      tiles :set, "#" => :red_art, "." => :blue_art
      field = background :field, tiles: :set, map: Array.new(32) { "#" * 32 }
      image(:dot, "#" => :white) { "##\n##" }
      dots = Array.new(40) { |i| sprite :dot, at: [(i % 8) * 8, 8 * (i / 8)] }
      turn = var :turn, 0
      game_loop do
        turn = 1 - turn
        dots.each { |dot| dot.x += 1 }
        field.scroll_by 1, 0
        if turn == 0
          cells.times { |i| field.set_tile i % 20, i / 20, "#" }
        else
          cells.times { |i| field.set_tile i % 20, i / 20, "." }
        end
      end
    end
    b.finalize_program
    b.program
  end
end
