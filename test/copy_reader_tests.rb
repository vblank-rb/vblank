# frozen_string_literal: true

require "digest"
require "tmpdir"
require "folder_original"

VBlank.require_game_file "fixtures/record_walk/record_walk_part"

# A PORT'S UNPACKING ROUTINE, PLAYED (Original::CopyReader, Original::Unpacking): the routine a
# port writes in `slots.fill_from_copy`, built as a program of its own and played by `game_player`.
# It runs in two places only: on the interpreter as a build makes its pack, and in a shell, which
# is a computer program. So these play on the run whose player is the interpreter and on the
# native, JavaScript and Ruby runs, each its own build of the routine checked against the
# interpreter, and never on a console's (test/interpreter/, test/lowering/{native,js,ruby}/, each
# under vblank/original/, include this module). The made-up original is MadeUpOriginal's.

# A MADE-UP PACKED FORMAT, written as a port writes one of its own (Original::Packing::Format):
# pairs of a count and a byte, the byte written that many times, each count multiplied by the
# `times:` setting, until a count of 0.
module PairRuns
  extend VBlank::Original::Packing::Format
  unpacks :pair_runs, times: 1

  # The most pairs a block can hold, a bound on the loop that reads them.
  MOST_PAIRS = 4096

  def self.routine(block)
    at = block.variable(:at)
    many = block.variable(:many)
    at.store!(block.from)
    many.store!(block.byte(at))
    block.repeat(MOST_PAIRS, stop_when: (many == 0) | block.finished) do
      block.repeat(many * block.setting(:times), stop_when: block.finished) { block.write(block.byte(at + 1)) }
      at.increase!(2)
      many.store!(block.byte(at))
    end
  end
end

module CopyReaderTests
  include FolderOriginal

  # A copy that is several files: each file read through copy.file, its places counted from that
  # file's start, the places in DATA.MU1 read out of INDEX.MU1 as the routine runs.
  def test_a_routine_reads_each_file_of_a_copy_that_is_several_files
    unpacking = VBlank::Builder.new.data_pack(from: folder_original, version: "1") { |slots| folder_slots(slots) }.unpacking
    played = unpacking.run_on(game_player, frames: 8)

    assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") }, unpacking.slot_bytes_in(played))
  end

  # The port's format, named in `formats:`, gives the copy `unpack_pair_runs`, with its setting.
  def test_a_format_of_the_ports_own_unpacks_and_counts_what_it_writes
    Dir.mktmpdir do |folder|
      from = copy_of(folder, [0xEE, 3, 7, 2, 9, 0, 0xEE].pack("C*"))
      unpacking = VBlank::Builder.new.data_pack(from: from, version: "1", formats: [PairRuns]) do |slots|
        slots.numbers :runs, count: 10, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.unpack_pair_runs at: 1, into: pack[:runs], times: 2 }
      end.unpacking
      played = unpacking.run_on(game_player, frames: 4)

      assert_equal({ runs: ([7] * 6 + [9] * 4).pack("C*") }, unpacking.slot_bytes_in(played))
      assert_equal 10, unpacking.bytes_done_in(played)
    end
  end

  # A shell shows how far the routine has got: the bytes written so far of the pack's whole size.
  def test_the_routine_says_how_far_it_has_got
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(VBlank::Builder.new, folder).unpacking

      assert_equal 32 + 64 + HEIGHTS.length, unpacking.byte_size
      early = unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the pack is unpacked"
      assert_operator early, :<, unpacking.byte_size, "...and not all of it, since each block waits for a frame"
      assert_equal unpacking.byte_size, unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 8))
    end
  end

  # One block big enough to take several frames: the count of bytes done moves on inside it, so a
  # shell's progress does not sit at nothing until the whole block is unpacked.
  def test_progress_moves_on_inside_one_big_block
    raw = (0...1024).map { |at| (at * 5) & 0x3F }.pack("C*")
    Dir.mktmpdir do |folder|
      from = copy_of(folder, Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize))
      unpacking = VBlank::Builder.new.data_pack(from: from, version: "1") do |slots|
        slots.numbers :big, count: raw.bytesize, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.unpack_lz77 at: 0, into: pack[:big] }
      end.unpacking

      early = unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the block is unpacked"
      assert_operator early, :<, raw.bytesize, "...and not all of it"
      assert_equal raw.bytesize, unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 10))
    end
  end

  # A routine can read the copy and write a slot a byte at a time, for a layout no building block
  # knows: here the speeds, read as halves high byte first, kept as their low bytes reversed.
  def test_a_routine_reads_and_writes_bytes_itself
    Dir.mktmpdir do |folder|
      unpacking = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :backwards, count: 4, width: :byte, signed: false
        slots.fill_from_copy do |copy, pack|
          4.times { |at| pack[:backwards][3 - at] = copy.half(SPEEDS_AT + (at * 2), big_endian: true) & 0xFF }
        end
      end.unpacking

      assert_equal [SPEEDS[1], SPEEDS[3], SPEEDS[5], SPEEDS[7]].reverse.pack("C*"),
                   unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 4))[:backwards]
    end
  end

  # A routine in normal Ruby, as a game block is written: a `while` on a number read from the copy
  # is a loop in the routine, played as it unpacks. The first speed is 10, so it goes round 8 times.
  # `at` is a number the routine changes as it plays, so it is one of the routine's variables.
  def test_a_routine_written_in_normal_ruby_loops_as_it_unpacks
    Dir.mktmpdir do |folder|
      from = original(folder)
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :doubled, count: 8, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            rounds = copy.byte(SPEEDS_AT) - 2
            while at < rounds
              pack[:doubled][at] = copy.byte(SPEEDS_AT + at) * 2
              at += 1
            end
          end
        end
      end
      unpacking = made_pack.unpacking

      assert_equal SPEEDS.map { |speed| (speed * 2) & 0xFF }.pack("C*"),
                   unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 4))[:doubled]
    end
  end

  # A LIST WALKED UNTIL A RECORD SAYS IT IS THE LAST, as an original walks a group of pictures:
  # records of four words (where from, where to, how many, another follows), two of them here.
  RECORDS_AT = 100
  RECORDS = Ractor.make_shareable([[1000, 0, 300, 1], [2000, 600, 200, 0]])

  private def record_copy
    bytes = (0...4096).map { |at| (at * 7) & 0xFF }.pack("C*")
    bytes[RECORDS_AT, 32] = RECORDS.flatten.pack("V*")
    bytes
  end

  # What the two records copy into a slot of 1024 bytes, the rest zero.
  private def records_copied(copy)
    out = "\0".b * 1024
    RECORDS.each { |from, to, count, _| out[to, count] = copy.byteslice(from, count) }
    out
  end

  # +walk+ is a method of RecordWalkPart (test/fixtures/record_walk), a part in a game file.
  private def walked_records(folder, copy, walk)
    from = copy_of(folder, copy)
    unpacking = VBlank::Builder.new.data_pack(from: from, version: "1") do |slots|
      slots.pixels :out, count: 1024
      slots.fill_from_copy do |reader, pack|
        part = RecordWalkPart.new(reader, pack)
        walk == :flag ? part.fill_with_flag(RECORDS_AT) : part.fill(RECORDS_AT)
      end
    end.unpacking
    unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 8))[:out]
  end

  # The loop's test reads a name its body sets from the copy, so the loop is the game's, and the
  # names it changes are the game's to keep, in a part's method as in a game block.
  def test_a_routine_walks_records_until_one_says_it_is_the_last
    Dir.mktmpdir do |folder|
      copy = record_copy

      assert_equal records_copied(copy), walked_records(folder, copy, :number), "kept as the number read"
      assert_equal records_copied(copy), walked_records(folder, copy, :flag), "kept as true or false"
    end
  end

  # A MADE-UP FORMAT NO BUILDING BLOCK KNOWS, decoded by the game's own code as a port writes it:
  # pairs of a count and a byte, the byte written that many times, until a count of 0. The
  # decoder says what it wrote with `count_written`, so the count of bytes done moves on, and the
  # routine waits for the next frame as the building blocks do.
  OWN_FORMAT_RUNS = Ractor.make_shareable([[200, 7], [150, 9], [255, 3], [255, 1], [140, 4]])
  OWN_FORMAT_BYTES = OWN_FORMAT_RUNS.flat_map { |many, byte| [byte] * many }.pack("C*").freeze

  def test_count_written_moves_progress_on_in_a_decoder_of_the_games_own
    Dir.mktmpdir do |folder|
      from = copy_of(folder, (OWN_FORMAT_RUNS.flatten + [0, 0]).pack("C*"))
      b = VBlank::Builder.new
      made_pack = nil
      b.instance_eval do
        made_pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :runs, count: OWN_FORMAT_BYTES.bytesize, width: :byte, signed: false
          slots.fill_from_copy do |copy, pack|
            at = 0
            out = 0
            many = copy.byte(at)
            while many > 0
              repeat(many) do
                pack[:runs][out] = copy.byte(at + 1)
                out += 1
              end
              copy.count_written many
              at += 2
              many = copy.byte(at)
            end
          end
        end
      end
      unpacking = made_pack.unpacking

      early = unpacking.bytes_done_in(unpacking.run_on(game_player, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the runs are counted"
      assert_operator early, :<, OWN_FORMAT_BYTES.bytesize, "...and not all of them, since the routine waits for a frame"
      played = unpacking.run_on(game_player, frames: 20)
      assert_equal({ runs: OWN_FORMAT_BYTES }, unpacking.slot_bytes_in(played))
      assert_equal OWN_FORMAT_BYTES.bytesize, unpacking.bytes_done_in(played)
    end
  end
end
