# frozen_string_literal: true

require "test_helper"

# A FRAME OF A SPRITE AS THE DATA PACK KEEPS IT (Original::FrameRecord): the record a layout's
# frame is written as, read back, and the section of a pack that holds every frame a game names.
# The answer key is the made-up frame's own numbers, written out here.
class TestFrameRecord < Minitest::Test
  Record = VBlank::Original::FrameRecord

  # Two bytes of count, high byte first, then six bytes a piece: x, y, the tile as a word whose top
  # bit is mirrored, a byte of two tiles-less-one numbers, and a byte the picture does not use.
  LAYOUT = VBlank::Original::FrameLayout.new(
    piece_bytes: 6, counted: true, count_bytes: 2, high_byte_first: true, x_at: 0, y_at: 1,
    tile_at: 2, tile_bytes: 2, tile_bits: 12, flags_at: 2, flags_bytes: 2, mirrored_bit: 15, bank_bit: 12, bank_bits: 2,
    size_at: 4, columns_bit: 4, rows_bit: 0, size_bits: 2, tile_order: :down_columns
  )
  PIECES = [[-8, 4, 0x8000 | (2 << 12) | 300, (2 << 4) | 1, 0xEE], [100, -100, 7, 0, 0xEE]].freeze
  FRAME = ([PIECES.length].pack("n") + PIECES.map { |piece| piece.pack("ccnCC") }.join).freeze
  SLOT = VBlank::Original::Slot.numbers(:frames, count: FRAME.bytesize + 3, width: :byte, signed: false, layout: :genesis)
  # The slot: three bytes that are no frame, then the frame.
  SLOT_BYTES = ("\x09\x09\x09".b + FRAME).freeze

  private def source(at: 3, count: nil, layout: LAYOUT) = Record::Source.new(slot: SLOT, at: at, count: count, layout: layout)

  def test_a_frame_is_written_as_its_pieces_in_the_records_own_layout
    frame = Record.read(source.record(SLOT_BYTES))
    first, second = frame.pieces

    assert_equal 2, frame.named
    assert_equal [-8, 4, 300, 3, 2, 2], [first.x, first.y, first.tile, first.columns, first.rows, first.bank]
    assert first.mirrored
    refute first.upside_down
    # Down columns: the tile below is the next one, and the next column starts a column's tiles on.
    assert_equal [300, 301, 302, 304], [first.tile_at(0, 0), first.tile_at(0, 1), first.tile_at(1, 0), first.tile_at(2, 0)]
    assert_equal [100, -100, 7, 1, 1, 0, false], [second.x, second.y, second.tile, second.columns, second.rows, second.bank, second.mirrored]
  end

  def test_a_record_is_four_bytes_and_sixteen_a_piece
    assert_equal Record::HEADER_BYTES + (2 * Record::PIECE_BYTES), source.record(SLOT_BYTES).bytesize
  end

  # The same piece read with tiles across rows steps the other way.
  def test_tiles_across_rows_are_the_records_steps
    piece = Record.read(source(layout: LAYOUT.with(tile_order: :across_rows)).record(SLOT_BYTES)).pieces.first

    assert_equal [300, 301, 303], [piece.tile_at(0, 0), piece.tile_at(1, 0), piece.tile_at(0, 1)]
  end

  # A frame that names more pieces than its slot holds keeps those that fit and says how many it names.
  def test_a_frame_that_runs_past_its_slot_keeps_the_pieces_that_fit
    short = SLOT_BYTES.byteslice(0, SLOT_BYTES.bytesize - 2)
    slot = SLOT.with(count: short.bytesize)
    frame = Record.read(Record::Source.new(slot: slot, at: 3, count: nil, layout: LAYOUT).record(short))

    assert_equal [2, 1], [frame.named, frame.pieces.length]
  end

  def test_a_frame_whose_count_the_game_gives_has_that_many_pieces
    frame = Record.read(source(at: 5, count: 1, layout: LAYOUT.with(counted: false)).record(SLOT_BYTES))

    assert_equal [1, 1, -8], [frame.named, frame.pieces.length, frame.pieces.first.x]
  end

  def test_a_section_holds_each_frame_where_its_directory_says
    uncounted = source(at: 5 + LAYOUT.piece_bytes, count: 1, layout: LAYOUT.with(counted: false))
    section = Record::Section.new(sources: [source, uncounted])
    bytes = section.bytes({ frames: SLOT_BYTES })
    read = Array.new(2) { |frame| Record.read_entry(bytes, entry_at: section.entry_at(frame), section_at: 0) }

    assert_equal section.size, bytes.bytesize
    assert_equal [2, 1], read.map { |frame| frame.pieces.length }
    assert_equal 100, read.last.pieces.first.x
  end

  # A section's size follows from what the game wrote alone: it is the same whatever the slot holds.
  def test_a_sections_size_does_not_depend_on_what_the_slot_holds
    section = Record::Section.new(sources: [source])
    empty = "\0".b * SLOT_BYTES.bytesize

    assert_equal section.bytes({ frames: SLOT_BYTES }).bytesize, section.bytes({ frames: empty }).bytesize
    assert_equal 0, Record::Section.new(sources: []).size
  end

  # Bytes that are a player's stop nothing: an entry that names no record, or one outside the
  # bytes, is a frame of no pieces, and pieces are read while they end inside the bytes.
  def test_reading_takes_only_what_is_inside_the_bytes
    section = Record::Section.new(sources: [source])
    bytes = section.bytes({ frames: SLOT_BYTES })
    cut = bytes.byteslice(0, section.records_at + Record::HEADER_BYTES + Record::PIECE_BYTES + 5)

    assert_empty Record.read_entry([0].pack("V"), entry_at: 0, section_at: 0).pieces
    assert_empty Record.read_entry([5000].pack("V"), entry_at: 0, section_at: 0).pieces
    assert_equal 1, Record.read_entry(cut, entry_at: 0, section_at: 0).pieces.length
  end

  def test_a_pack_keeps_its_frame_records_after_its_slots
    records = Record::Section.new(sources: [source]).bytes({ frames: SLOT_BYTES })
    pack = VBlank::Original::Pack.holding({ frames: SLOT_BYTES }, sha1: "ab" * 20, build_version: "1", frame_records: records)
    read = VBlank::Original::Pack.from_bytes(pack.to_bytes)

    assert_equal records, read.frame_records
    assert_equal SLOT_BYTES, read.bytes_of(:frames)
    assert pack.to_bytes.end_with?(records)
    assert_empty VBlank::Original::Pack.from_bytes(VBlank::Original::Pack.holding({ frames: SLOT_BYTES }, sha1: "ab" * 20, build_version: "1").to_bytes).frame_records
  end
end
