# frozen_string_literal: true

require "test_helper"

# THE GENESIS'S OWN TILE LAYOUT, read by IR::FormatReading, held to what its lowering writes. (Its
# colours are held to GenesisHardware.color_word in test/all/vblank/ir/test_format_reading.rb.)
class TestGenesisFormatReading < Minitest::Test
  Reading = VBlank::IR::FormatReading

  # A tile the lowering writes (Art#tile_bytes, which keeps no state) reads back as its places.
  def test_a_tile_the_lowering_writes_reads_back_as_its_places
    places = (0...64).map { |at| ((at * 7) + (at / 8)) % 16 }
    bytes = VBlank::IR::Backends::Genesis::Art.allocate.tile_bytes(places)
    format = VBlank::Console.for(:genesis).original_formats.tiles_of(16)

    assert_equal [places], Reading.tiles(bytes, format)
  end
end
