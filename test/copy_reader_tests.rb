# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_data_packs"

# A PORT'S UNPACKING ROUTINE, PLAYED (Original::CopyReader, Original::Unpacking): the routine a
# port writes in `slots.fill_from_copy`, built as a program of its own and played by `game_player`.
# It runs in two places only: on the interpreter as a build makes its pack, and in a shell, which
# is a computer program. So these play on the run whose player is the interpreter and on the
# native, JavaScript and Ruby runs, each its own build of the routine checked against the
# interpreter, and never on a console's (test/interpreter/, test/lowering/{native,js,ruby}/, each
# under vblank/original/, include this module). The made-up original is MadeUpOriginal's.
module CopyReaderTests
  include MadeUpOriginal

  # A shell shows how far the routine has got: the bytes written so far of the pack's whole size.
  def test_the_routine_says_how_far_it_has_got
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(VBlank::Builder.new, folder).unpacking

      assert_equal 32 + 64 + HEIGHTS.length, unpacking.byte_size
      early = unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the pack is unpacked"
      assert_operator early, :<, unpacking.byte_size, "...and not all of it, since each block waits for a frame"
      assert_equal unpacking.byte_size, unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 8))
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

      early = unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 1))
      assert_operator early, :>, 0, "a frame in, some of the block is unpacked"
      assert_operator early, :<, raw.bytesize, "...and not all of it"
      assert_equal raw.bytesize, unpacking.bytes_done_in(game_player.run(unpacking.program, frames: 10))
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
                   unpacking.slot_bytes_in(game_player.run(unpacking.program, frames: 4))[:backwards]
    end
  end

  # A routine in normal Ruby, as a game block is written: a `while` on a number read from the copy
  # is a loop in the routine, played as it unpacks. The first speed is 10, so it goes round 8 times.
  # `at` is a number the routine changes as it plays, so it is one of the routine's variables.
  def test_a_routine_written_in_normal_ruby_loops_as_it_unpacks
    Dir.mktmpdir do |folder|
      from = original(folder)
      b = VBlank::Builder.new
      b.instance_eval do
        @made_pack = data_pack(from: from, version: "1") do |slots|
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
      unpacking = b.instance_variable_get(:@made_pack).unpacking

      assert_equal SPEEDS.map { |speed| (speed * 2) & 0xFF }.pack("C*"),
                   unpacking.slot_bytes_in(game_player.run(unpacking.program, frames: 4))[:doubled]
    end
  end
end
