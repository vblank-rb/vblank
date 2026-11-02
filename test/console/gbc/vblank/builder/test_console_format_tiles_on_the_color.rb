# frozen_string_literal: true

require "test_helper"

# TILES A GAME PAINTS IN THE COLOR'S OWN FORM (`console_format: true`). The list holds what picture
# memory holds, sixteen bytes a tile, so nothing is converted as the game runs: two bytes a row, the
# low bit of each pixel in the first and the high bit in the second, the leftmost pixel in bit 7.
class TestConsoleFormatTilesOnTheColor < Minitest::Test
  RED = Color.resolve(:red)
  BLUE = Color.resolve(:blue)
  WHITE = Color.resolve(:white)

  # A tile whose left half is place 1 and whose right half is place 2, then a tile of place 3.
  TWO_TILES = (([0xF0, 0x0F] * 8) + ([0xFF, 0xFF] * 8)).freeze

  private def painted
    bytes = TWO_TILES
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :red, :blue, :white]
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(32) { canvas.push 0 }
      box = tiles :box, from: canvas, count: 2, colors: :ink, console_format: true
      background :front, tiles: :box, map: [[1, 2]]
      bytes.each_with_index { |byte, at| canvas[at] = byte }
      box.changed
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_list_in_the_colors_own_form_shows_as_it_reads
    screen = game_player.run(painted, frames: 3).screen

    assert_equal RED, screen.pixel(1, 1), "the first tile's left half"
    assert_equal BLUE, screen.pixel(6, 1), "the first tile's right half"
    assert_equal WHITE, screen.pixel(12, 1), "the second tile"
  end

  # A picture a sprite shows takes it too, its tiles side by side in the list.
  def test_a_sprites_picture_takes_the_colors_own_form
    bytes = TWO_TILES
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :red, :blue, :white]
      canvas = list :canvas, capacity: 32, width: :byte
      repeat(32) { canvas.push 0 }
      tag = image :tag, from: canvas, width: 16, height: 8, colors: :ink, console_format: true
      sprite :tag, at: [40, 20]
      bytes.each_with_index { |byte, at| canvas[at] = byte }
      tag.changed
      game_loop { wait_vblank }
    end
    b.finalize_program
    screen = game_player.run(b.program, frames: 3).screen

    assert_equal RED, screen.pixel(41, 21)
    assert_equal WHITE, screen.pixel(52, 21)
  end
end
