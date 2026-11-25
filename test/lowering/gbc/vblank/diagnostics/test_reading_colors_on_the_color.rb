# frozen_string_literal: true

require "test_helper"

# What the reader of a running Color cartridge says its background colours are: the colour memory
# itself, read from the emulator in groups of four. A tile's places name a colour in its group, the
# group's first being the backdrop, so a game's backdrop and its tile's colours are read back where
# the cartridge put them. The reader was right where this was written; these hold it there.
class TestReadingColorsOnTheColor < Minitest::Test
  BACKDROP = VBlank::Graphics::Color.rgb(8, 16, 31)
  RED = VBlank::Graphics::Color.rgb(31, 0, 0)

  # One tile, red with its left half see-through, filling a tiled screen that has a backdrop.
  private def backdrop_and_red_tile
    backdrop = BACKDROP
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: backdrop
      image :half, "." => :transparent, "#" => :red do
        ("....####\n" * 8)
      end
      tiles :half_tiles, "#" => :half
      background :field, tiles: :half_tiles, map: ["#" * 20] * 18
      game_loop { }
    end
    b.finalize_program
    b.program
  end

  # The backdrop is the first colour of the group and the tile's red the second; the other two
  # places are unused and nought.
  def test_the_backgrounds_colours_are_the_backdrop_then_the_tiles_red
    rom = VBlank::Console.for(:gbc).builder.cartridge_for(backdrop_and_red_tile, title: "COLOURS")

    [3, 30].each do |frame|
      reader = VBlank::Diagnostics::Verifier.new(rom, frames: frame)

      assert_equal [BACKDROP, RED, 0, 0], reader.palette(:backgrounds, 0), "frame #{frame}"
    end
  end
end
