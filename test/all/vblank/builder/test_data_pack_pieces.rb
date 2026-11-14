# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "pieced_original"

# A PART OF THE UNPACKING IN PIECES (`slots.fill_from_copy :music, pieces: n`, a slot's
# `pieces:`): the pack is the same however the music is cut, and the routine split for several
# workers (Original::PiecedUnpacking) makes it byte for byte; what would make a piece's own
# program write another pack is refused as the routine is built.
class TestDataPackPieces < Minitest::Test
  include PiecedOriginal

  private def pack_file_with(pieces)
    Dir.mktmpdir do |folder|
      builder = Builder.new
      builder.data_pack(from: pieced_original(folder), version: "1") { |slots| PiecedOriginal.declare(slots, pieces: pieces) }
      builder.made_data_pack_file
    end
  end

  def test_the_pack_is_the_same_with_no_pieces_one_piece_and_a_piece_a_song
    unpieced = pack_file_with(:none)

    assert_equal unpieced, pack_file_with(1)
    assert_equal unpieced, pack_file_with(:songs)
  end

  def test_each_song_is_in_its_room_and_the_song_the_copy_lacks_stays_zeros
    pack = VBlank::Original::Pack.from_bytes(pack_file_with(:songs))

    assert_equal PiecedOriginal.music_answer, pack.bytes_of(:music)
    assert_equal ROOMS.each_with_index.map { |room, song| song == ABSENT ? 0 : room }, pack.bytes_of(:music_length).unpack("v*")
    assert_equal HEIGHTS.pack("C*"), pack.bytes_of(:heights)
  end

  # Each program of the split played on its own, as a worker plays it, and the pieces copied over
  # the parts' bytes: the whole routine's pack, byte for byte.
  def test_the_routine_split_for_workers_joins_into_the_whole_routines_pack
    Dir.mktmpdir do |folder|
      builder = Builder.new
      pack = builder.data_pack(from: pieced_original(folder), version: "1") { |slots| PiecedOriginal.declare(slots, pieces: :songs) }
      whole = pack.unpacking
      split = pack.pieced_unpacking
      whole_bytes = whole.run_as_ruby(frames: whole.most_frames).list_bytes(VBlank::Original::Unpacking::BYTES)
      runs = split.programs.map { |unpacking| unpacking.run_as_ruby(frames: unpacking.most_frames) }

      assert_equal ROOMS.length, split.pieces.length
      assert(runs.all? { |run| run[VBlank::Original::Unpacking::FINISHED] == 1 })
      bytes = runs.map { |run| run.list_bytes(VBlank::Original::Unpacking::BYTES) }
      assert_equal whole_bytes.b, split.join(bytes.first, bytes.drop(1))
    end
  end

  def test_the_queue_hands_out_the_piece_of_most_work_first
    Dir.mktmpdir do |folder|
      pack = Builder.new.data_pack(from: pieced_original(folder), version: "1") { |slots| PiecedOriginal.declare(slots, pieces: :songs) }

      assert_equal [2, 0, 4, 1, 3], pack.pieced_unpacking.queue_order
    end
  end

  def test_a_routine_with_no_part_in_pieces_has_no_split
    Dir.mktmpdir do |folder|
      pack = Builder.new.data_pack(from: pieced_original(folder), version: "1") { |slots| PiecedOriginal.declare(slots, pieces: :none) }

      assert_nil pack.pieced_unpacking
    end
  end

  def test_the_workers_are_one_a_processor_and_never_more
    assert_equal 8, VBlank::Original::PiecedUnpacking.worker_count(nil, processors: 8)
    assert_equal 3, VBlank::Original::PiecedUnpacking.worker_count(3, processors: 8)
    assert_equal 8, VBlank::Original::PiecedUnpacking.worker_count(64, processors: 8)
    assert_raises(ArgumentError) { VBlank::Original::PiecedUnpacking.worker_count(0, processors: 8) }
  end

  # THE REFUSALS, each a pack whose split would not make the whole routine's pack.
  private def refusal_of
    Dir.mktmpdir do |folder|
      assert_raises(ArgumentError) do
        Builder.new.data_pack(from: pieced_original(folder), version: "1") do |slots|
          slots.tiles :walls, count: 2
          slots.samples :music, count: 10, pieces: 2
          slots.numbers :lengths, count: 3, width: :byte, signed: false, pieces: 3
          yield slots
        end
      end.message
    end
  end

  def test_a_part_in_pieces_writing_a_whole_slot_is_refused
    refused = refusal_of { |slots| slots.fill_from_copy(:music, pieces: 2) { |copy, pack| pack[:walls][0] = copy.byte(0) } }

    assert_match "has pieces:, and it writes slot :walls", refused
  end

  def test_a_part_in_pieces_writing_another_pieces_number_is_refused
    refused = refusal_of { |slots| slots.fill_from_copy(:music, pieces: 2) { |copy, pack| pack[:music].piece(1)[0] = copy.byte(0) } }

    assert_match "writes piece 1 of slot :music while it makes piece 0", refused
  end

  def test_a_part_in_pieces_reading_a_slot_another_part_writes_is_refused
    refused = refusal_of do |slots|
      slots.fill_from_copy(:walls) { |copy, pack| copy.unpack_lz77 at: LZ77_AT, into: pack[:walls] }
      slots.fill_from_copy(:music, pieces: 2) { |_copy, pack, _release, piece| pack[:music].piece(piece)[0] = pack[:walls][0] }
    end

    assert_match "has pieces:, and it reads slot :walls", refused
  end

  def test_a_part_without_pieces_reading_a_slot_in_pieces_is_refused
    refused = refusal_of do |slots|
      slots.fill_from_copy(:music, pieces: 2) { |copy, pack, _release, piece| pack[:music].piece(piece)[0] = copy.byte(0) }
      slots.fill_from_copy(:walls) { |_copy, pack| pack[:walls][0] = pack[:music][0] }
    end

    assert_match "reads slot :music, and that slot is in pieces", refused
  end

  def test_a_part_whose_pieces_are_not_the_slots_is_refused
    refused = refusal_of do |slots|
      slots.fill_from_copy(:music, pieces: 2) { |copy, pack, _release, piece| pack[:lengths].piece(piece)[0] = copy.byte(0) }
    end

    assert_match "has pieces: 2, and slot :lengths is in 3 pieces", refused
  end

  def test_a_slot_in_pieces_written_by_two_parts_is_refused
    refused = refusal_of do |slots|
      %i[music more_music].each do |part|
        slots.fill_from_copy(part, pieces: 2) { |copy, pack, _release, piece| pack[:music].piece(piece)[0] = copy.byte(0) }
      end
    end

    assert_match "each write slot :music", refused
  end

  def test_pieces_that_do_not_add_up_to_the_slot_are_refused
    Dir.mktmpdir do |folder|
      refused = assert_raises(ArgumentError) do
        Builder.new.data_pack(from: pieced_original(folder), version: "1") { |slots| slots.samples :music, count: 10, pieces: [4, 5] }
      end

      assert_match "pieces: [4, 5]", refused.message
    end
  end

  def test_a_slot_copied_as_it_is_cannot_be_in_pieces
    Dir.mktmpdir do |folder|
      refused = assert_raises(ArgumentError) do
        Builder.new.data_pack(from: pieced_original(folder), version: "1") { |slots| slots.samples :music, at: 0, count: 10, pieces: 2 }
      end

      assert_match "has at: and pieces:", refused.message
    end
  end
end
