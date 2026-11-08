# frozen_string_literal: true

require "test_helper"

# THE COLOR'S OWN LAYOUT, read by IR::FormatReading, held to what the Color's lowering writes.
class TestGBCFormatReading < Minitest::Test
  GBC = VBlank::IR::Backends::GBC
  Reading = VBlank::IR::FormatReading

  private def formats = VBlank::Console.for(:gbc).original_formats

  # A tile the lowering writes (TileBytes) reads back as its places.
  def test_a_tile_the_lowering_writes_reads_back_as_its_places
    places = (0...64).map { |at| ((at * 7) + (at / 8)) % 4 }
    bytes = GBC::TileBytes.of(places).pack("C*")

    assert_equal [places], Reading.tiles(bytes, formats.tiles_of(4))
  end

  # The words the lowering writes for a palette (SM83#data_words) read back as the colours.
  def test_a_colour_the_lowering_writes_reads_back_as_the_colour
    colors = (0...0x8000).step(97).to_a
    asm = GBC::SM83.new("colors")
    asm.data_words(colors)

    assert_equal colors, Reading.colors(asm.bytes, formats.colors)
  end
end
