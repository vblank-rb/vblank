# frozen_string_literal: true

require "test_helper"

# ONE CELL OF A BACKGROUND'S MAP AS THE DATA PACK KEEPS IT (Original::MapCell). The answer key is
# the layout the record's comment and original.md write down: the tile in two bytes, low byte
# first, then the bank, then the turns, 1 mirrored and 2 upside down.
class TestMapCell < Minitest::Test
  MapCell = VBlank::Original::MapCell

  def test_a_cell_is_its_tile_low_byte_first_then_its_bank_then_its_turns
    bytes = MapCell.bytes_of([MapCell::Cell.new(tile: 0x1234, bank: 5, mirrored: true),
                              MapCell::Cell.new(tile: 767, bank: 7, upside_down: 1, mirrored: 0)])

    assert_equal [0x34, 0x12, 5, 1, 0xFF, 0x02, 7, 2], bytes.bytes
  end

  def test_a_turn_given_as_a_number_reads_its_lowest_bit
    assert_equal [1, 0, 0, 3], MapCell.bytes(tile: 1, mirrored: 0x21 >> 5, upside_down: 0x6F >> 6)
  end

  def test_every_reader_of_a_map_reads_the_record_as_written
    word = MapCell.bytes_of([MapCell::Cell.new(tile: 700, bank: 6, upside_down: true)]).unpack1("V")
    tile = MapCell::FORMAT.cell_tile(word, 0, 0, 1)

    assert_equal [700, 6, false, true], [tile.tile, tile.bank, tile.mirrored, tile.upside_down]
  end

  # The record as one number is its four bytes read low byte first, and fits a game's number.
  def test_the_record_as_one_number_is_its_bytes_read_low_byte_first
    cell = MapCell::Cell.new(tile: 0xFFFF, bank: 0xFF, mirrored: true, upside_down: true)

    assert_equal MapCell.bytes_of([cell]).unpack1("V"), cell.number
    assert_operator cell.number, :<=, 0x7FFF_FFFF
  end

  # A tile past two bytes would run into the bank, and name another cell.
  def test_a_number_of_a_tile_past_its_part_is_refused
    error = assert_raises(ArgumentError) { MapCell.number(tile: 70_000) }

    assert_includes error.message, "70000"
  end
end
