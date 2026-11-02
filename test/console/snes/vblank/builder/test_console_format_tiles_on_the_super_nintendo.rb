# frozen_string_literal: true

require "test_helper"

# TILES A GAME PAINTS IN THE SUPER NINTENDO'S OWN FORM (`console_format: true`). The list holds what
# video memory holds, 32 bytes a tile, so nothing is converted as the game runs: sixteen bytes of
# bit planes 0 and 1, a row at a time, then sixteen of planes 2 and 3, the leftmost pixel in bit 7.
class TestConsoleFormatTilesOnTheSuperNintendo < Minitest::Test
  RED = Color.resolve(:red)
  BLUE = Color.resolve(:blue)

  # The left half of the tile is place 1 (plane 0), the right half place 8 (plane 3).
  TILE = (([0xF0, 0x00] * 8) + ([0x00, 0x0F] * 8)).freeze

  def test_a_list_in_the_consoles_own_form_shows_as_it_reads
    bytes = TILE
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :red, 0, 0, 0, 0, 0, 0, :blue]
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(32) { canvas.push 0 }
      box = tiles :box, from: canvas, count: 1, colors: :ink, console_format: true
      background :front, tiles: :box, map: [[1]]
      bytes.each_with_index { |byte, at| canvas[at] = byte }
      box.changed
      game_loop { wait_vblank }
    end
    b.finalize_program
    screen = game_player.run(b.program, frames: 3).screen

    assert_equal RED, screen.pixel(1, 1)
    assert_equal BLUE, screen.pixel(6, 1)
  end
end
