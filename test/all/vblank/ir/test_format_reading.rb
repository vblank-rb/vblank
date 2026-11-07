# frozen_string_literal: true

require "test_helper"

# READING A CONSOLE'S OWN LAYOUT (IR::FormatReading), held to what that console's lowering writes.
class TestFormatReading < Minitest::Test
  Reading = VBlank::IR::FormatReading
  Genesis = VBlank::Console::GenesisHardware

  # A colour the Genesis's lowering writes into its colour memory (GenesisHardware.color_word),
  # read back in the Genesis's layout, is the colour the Genesis shows (GenesisHardware.shown_color).
  def test_a_genesis_colour_reads_back_as_the_genesis_shows_it
    colors = (0...0x8000).step(97).to_a
    kept = colors.map { |color| Genesis.color_word(color) }.pack("n*")

    assert_equal colors.map { |color| Genesis.shown_color(color) }, Reading.colors(kept, Genesis::ORIGINAL_FORMATS.colors)
  end

  # A tile each console's lowering writes into its cartridge, read back in that console's layout,
  # is the tile's places. The writers keep no state, so each is asked of a bare instance of its
  # picture builder.
  def test_a_tile_each_lowering_writes_reads_back_as_its_places
    places = (0...64).map { |at| ((at * 7) + (at / 8)) % 16 }
    backends = VBlank::IR::Backends
    written = {
      gbc: [4, backends::GBC::Art.allocate.send(:encode, places.map { |place| place % 4 }).pack("C*")],
      snes: [16, backends::SNES::Art.allocate.send(:tile_bytes, places)],
      genesis: [16, backends::Genesis::Art.allocate.send(:tile_bytes, places)]
    }

    written.each do |console, (colors, bytes)|
      format = VBlank::Console.for(console).original_formats.tiles_of(colors)

      assert_equal [places.map { |place| place % colors }], Reading.tiles(bytes, format), console
    end
  end
end
