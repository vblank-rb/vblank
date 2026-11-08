# frozen_string_literal: true

require "test_helper"

# THE SUPER NINTENDO'S OWN LAYOUT, read by IR::FormatReading, held to what its lowering writes.
class TestSNESFormatReading < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Reading = VBlank::IR::FormatReading

  private def formats = VBlank::Console.for(:snes).original_formats

  # A tile of sixteen colours the lowering writes (TileBytes) reads back as its places.
  def test_a_tile_the_lowering_writes_reads_back_as_its_places
    places = (0...64).map { |at| ((at * 7) + (at / 8)) % 16 }
    bytes = SNES::TileBytes.of(places)

    assert_equal [places], Reading.tiles(bytes, formats.tiles_of(16))
  end

  # The colour memory the lowering writes (Art#cgram) reads back as the colours it holds.
  def test_the_colour_memory_the_lowering_writes_reads_back_as_its_colours
    art = SNES::Art.new
    art.background_cell(picture(0x001F, 0x7C00))
    memory = art.cgram

    assert_equal memory.unpack("v*"), Reading.colors(memory, formats.colors)
    assert_includes memory.unpack("v*"), 0x7C00
  end

  private def picture(top, bottom)
    pixels = (Array.new(32, top) + Array.new(32, bottom)).pack("v*")
    VBlank::IR::Assets::Image.new(width: 8, height: 8, transparent: nil, pixels: pixels, colors: [0, top, bottom], places: nil)
  end
end
