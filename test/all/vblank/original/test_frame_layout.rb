# frozen_string_literal: true

require "test_helper"

# HOW AN ORIGINAL KEEPS ONE FRAME OF A SPRITE (Original::FrameLayout), read for a piece whose size
# is the Game Boy Advance's own pair of numbers: a shape (square, wide or tall) and a size of that
# shape. The answer key is the console's table of sprite sizes, written out here in tiles of 8x8.
class TestFrameLayout < Minitest::Test
  # Five bytes a piece: x, y, a flags byte (shape in bits 6 and 7, size in bits 4 and 5, mirrored
  # in bit 2, upside down in bit 3), then a word low byte first whose low ten bits are the tile.
  LAYOUT = VBlank::Original::FrameLayout.new(
    piece_bytes: 5, counted: true, x_at: 0, y_at: 1, flags_at: 2, mirrored_bit: 2, upside_down_bit: 3,
    tile_at: 3, tile_bytes: 2, tile_bits: 10, high_byte_first: false, shape_bit: 6, shape_size_bit: 4,
    tile_order: :across_rows
  )

  # The Advance's table: [columns, rows] in tiles, by shape, then by size.
  SIZES = [
    [[1, 1], [2, 2], [4, 4], [8, 8]],
    [[2, 1], [4, 1], [4, 2], [8, 4]],
    [[1, 2], [1, 4], [2, 4], [4, 8]]
  ].freeze

  private def piece_of(shape, size, layout: LAYOUT)
    bytes = [-3, 5, (shape << 6) | (size << 4), 0x2C, 0xF1].pack("ccCCC")
    layout.piece_from { |at| bytes.getbyte(at) }
  end

  def test_every_shape_and_size_reads_as_the_advances_table
    SIZES.each_with_index do |sizes, shape|
      sizes.each_with_index do |(columns, rows), size|
        piece = piece_of(shape, size)

        assert_equal [columns, rows], [piece.columns, piece.rows], "shape #{shape}, size #{size}"
        # Across rows: the tile right of the first is the next, and the next row starts a row's tiles on.
        assert_equal [1, columns], [piece.column_step, piece.row_step], "shape #{shape}, size #{size}"
      end
    end
  end

  def test_the_other_parts_of_a_piece_read_as_before
    piece = piece_of(1, 2)

    assert_equal [-3, 5, 0x12C, 0], [piece.x, piece.y, piece.tile, piece.turns]
  end

  # The console has no fourth shape. A piece that names it is read as a square of its size.
  def test_a_piece_of_the_fourth_shape_is_a_square
    assert_equal [[1, 1], [2, 2], [4, 4], [8, 8]], (0..3).map { |size| piece_of(3, size).then { |piece| [piece.columns, piece.rows] } }
  end

  def test_a_shape_with_no_size_is_refused
    error = assert_raises(ArgumentError) { LAYOUT.with(shape_size_bit: nil) }

    assert_includes error.message, "shape_size_bit:"
  end

  def test_a_size_with_no_shape_is_refused
    error = assert_raises(ArgumentError) { LAYOUT.with(shape_bit: nil) }

    assert_includes error.message, "shape_bit:"
  end

  def test_a_shape_and_a_big_bit_are_refused
    error = assert_raises(ArgumentError) { LAYOUT.with(big_bit: 5) }

    assert_includes error.message, "big_bit:"
  end

  def test_a_shape_and_a_size_byte_are_refused
    error = assert_raises(ArgumentError) { LAYOUT.with(size_at: 4, columns_bit: 2, rows_bit: 0) }

    assert_includes error.message, "size_at:"
  end

  def test_a_shape_with_no_tile_order_is_refused
    error = assert_raises(ArgumentError) { LAYOUT.with(tile_order: nil) }

    assert_includes error.message, "tile_order:"
  end

  def test_a_shape_ending_past_the_flags_is_refused
    error = assert_raises(ArgumentError) { LAYOUT.with(shape_bit: 7) }

    assert_includes error.message, "shape_bit:"
  end
end
