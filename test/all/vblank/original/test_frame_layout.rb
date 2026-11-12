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

  # A PIECE READ BY A READER THE GAME WRITES (piece:), here an original whose piece names a block of
  # sprite memory counted from the object's own block, the object's block given by the pose. The
  # blocks are 8 tiles across and 4 down, two across a row of 16 tiles: the answer key is that table
  # written out, block by block.
  BLOCK_STARTS = [0, 8, 64, 72, 128, 136, 192, 200, 256, 264, 320, 328, 384, 392, 448, 456].freeze
  BLOCK_START = ->(block) { ((block & 1) << 3) + (((block >> 1) & 3) << 6) + ((block >> 3) << 8) }
  READ_PIECE = lambda do |bytes, pose|
    block = (bytes[2] + pose[:block]) & 15
    big = (bytes[4] >> 5) & 1
    VBlank::Original::FrameLayout::Piece.new(
      x: bytes.signed(0), y: bytes.signed(1), tile: BLOCK_START.(block) | bytes[3], columns: big + 1, rows: big + 1,
      row_step: 16, mirrored: (bytes[4] >> 6) & 1, upside_down: (bytes[4] >> 7) & 1
    )
  end
  READ = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: READ_PIECE)

  private def read_piece(bytes, layout: READ, pose: { block: 5 })
    layout.piece_from(pose: pose) { |at| bytes.pack("C*").getbyte(at) }
  end

  private def reader_layout(&reader) = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: reader)

  def test_a_reader_the_game_writes_reads_each_part_of_a_piece
    piece = read_piece([0xFD, 5, 2, 0x12, 0x60])

    assert_equal [-3, 5, BLOCK_STARTS.fetch(7) | 0x12], [piece.x, piece.y, piece.tile]
    assert_equal [2, 2, 1, 16], [piece.columns, piece.rows, piece.column_step, piece.row_step]
    assert_equal VBlank::Original::FrameRecord::MIRRORED, piece.turns
  end

  def test_the_block_the_pose_gives_is_added_and_wraps_at_sixteen
    assert_equal BLOCK_STARTS.fetch(1) | 3, read_piece([0, 0, 12, 3, 0x80]).tile
    assert_equal VBlank::Original::FrameRecord::UPSIDE_DOWN, read_piece([0, 0, 12, 3, 0x80]).turns
    assert_equal BLOCK_STARTS.fetch(2), read_piece([0, 0, 2, 0, 0], pose: { block: 0 }).tile
  end

  def test_a_reader_names_the_pose_values_it_reads
    assert_equal [:block], READ.pose_names
    assert_equal [], LAYOUT.pose_names
  end

  READ_WITHOUT_POSE = ->(bytes) { VBlank::Original::FrameLayout::Piece.new(x: bytes[0], y: bytes[1], tile: bytes[2]) }
  READ_BANK = ->(bytes) { VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: bytes[2], bank: bytes[4] & 3) }

  def test_a_reader_of_one_argument_needs_no_pose
    layout = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: READ_WITHOUT_POSE)
    piece = read_piece([4, 6, 9, 0, 0], layout: layout, pose: {})

    assert_equal [4, 6, 9, 1, 1, 1, 1, 0, 0],
                 [piece.x, piece.y, piece.tile, piece.columns, piece.rows, piece.column_step, piece.row_step, piece.turns, piece.bank]
  end

  def test_a_reader_that_gives_a_bank_names_its_bank
    layout = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: READ_BANK)

    assert_predicate layout, :names_bank?
    refute_predicate READ, :names_bank?
  end

  # A READER EVERY RACTOR CAN SHARE. A game's tests build in Ractors, and a layout in a constant is
  # read by all of them, so a reader that cannot cross from one Ractor to another is refused at the
  # layout's line, not where a test first reads it in a Ractor of its own.
  def test_a_reader_that_uses_a_local_variable_is_refused
    widths = [1, 2]
    # Made with a module as its self, as a reader at the top of one is, so the local is all Ruby refuses.
    reader = VBlank.instance_exec { ->(bytes) { VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: bytes[2], columns: widths.first) } }
    error = assert_raises(ArgumentError) { VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: reader) }

    assert_includes error.message, "`widths`"
    assert_includes error.message, "constant"
  end

  def test_a_reader_written_inside_a_method_is_refused
    error = assert_raises(ArgumentError) do
      reader_layout { |bytes| VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: bytes[2]) }
    end

    assert_includes error.message, "inside a method"
    assert_includes error.message, "constant"
  end

  def test_a_constant_reader_is_read_in_another_ractor
    layout = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: READ_WITHOUT_POSE)
    tile = Ractor.new(Ractor.make_shareable(layout)) { |frame| frame.piece_from { |at| [0, 0, 7, 0, 0].fetch(at) }.tile }.value

    assert_equal 7, tile
  end

  def test_the_pose_values_a_frame_is_given_are_checked
    assert_equal({ block: 5 }, READ.pose_values_for({ block: 5 }))
    assert_includes assert_raises(ArgumentError) { READ.pose_values_for({}) }.message, "block"
    assert_includes assert_raises(ArgumentError) { READ.pose_values_for({ block: 5, colour: 1 }) }.message, "colour"
    assert_includes assert_raises(ArgumentError) { READ.pose_values_for({ block: :five }) }.message, "whole number"
    assert_includes assert_raises(ArgumentError) { LAYOUT.pose_values_for({ block: 5 }) }.message, "block"
  end

  def test_a_reader_that_indexes_a_ruby_array_with_a_byte_is_refused
    sizes = [1, 2, 4, 8]
    error = assert_raises(ArgumentError) do
      reader_layout { |bytes| VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: 0, columns: sizes[bytes[4] & 3]) }
    end

    assert_includes error.message, "Array"
  end

  def test_a_reader_that_looks_up_a_ruby_hash_with_a_byte_is_refused
    sizes = { 0 => 1, 1 => 2 }
    error = assert_raises(ArgumentError) do
      reader_layout { |bytes| VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: 0, columns: sizes[bytes[4] & 1]) }
    end

    assert_includes error.message, "Hash"
  end

  def test_a_reader_that_tests_a_byte_is_refused
    tests = [
      ->(bytes) { bytes[4] == 1 ? 2 : 1 },
      ->(bytes) { (bytes[4] & 0x20) > 0 ? 2 : 1 }, # rubocop:disable Style/NumericPredicate
      ->(bytes) { (bytes[4] & 1).zero? ? 1 : 2 },
      ->(bytes) { bytes[4].nil? ? 1 : 2 },
      lambda do |bytes|
        case bytes[4]
        when 0..3 then 1
        else 2
        end
      end
    ]
    tests.each do |columns_of|
      error = assert_raises(ArgumentError) do
        reader_layout { |bytes| VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: 0, columns: columns_of.(bytes)) }
      end

      assert_includes error.message, "shifts, masks and sums"
    end
  end

  def test_a_reader_with_a_byte_on_the_right_of_a_shift_is_refused
    error = assert_raises(ArgumentError) do
      reader_layout { |bytes| VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: 0, columns: 1 << (bytes[4] & 3)) }
    end

    assert_includes error.message, "on the left"
  end

  def test_a_reader_that_does_not_give_back_a_piece_is_refused
    error = assert_raises(ArgumentError) { reader_layout { |bytes| { x: bytes[0], y: bytes[1], tile: bytes[2] } } }

    assert_includes error.message, "FrameLayout::Piece"
  end

  def test_a_reader_that_reads_past_its_piece_is_refused
    error = assert_raises(ArgumentError) { reader_layout { |bytes| VBlank::Original::FrameLayout::Piece.new(x: 0, y: 0, tile: bytes[5]) } }

    assert_includes error.message, "byte 5"
  end

  def test_a_reader_with_the_layouts_own_places_is_refused
    error = assert_raises(ArgumentError) do
      VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: READ_PIECE, x_at: 0)
    end

    assert_includes error.message, "x_at:"
  end

  def test_a_layout_with_neither_a_reader_nor_places_is_refused
    error = assert_raises(ArgumentError) { VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true) }

    assert_includes error.message, "piece:"
  end
end
