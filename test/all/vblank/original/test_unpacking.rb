# frozen_string_literal: true

require "test_helper"
require "made_up_original"

# The build plays a port's unpacking routine built as Ruby (Original::Unpacking#run_as_ruby), which
# counts no steps, so a watchdog stops a routine that never waits for a frame.
class TestUnpacking < Minitest::Test
  include MadeUpOriginal

  PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
  STUCK_AFTER_SECONDS = 0.5

  # Built with the pack left out, so the build does not play the routine itself and the test can,
  # handed a blank copy.
  private def unpacking_of(folder, &routine)
    from = original(folder)
    unpacking = Builder.new(options: PACK_AT_START).instance_eval do
      data_pack(from: from, version: "1") do |slots|
        slots.tiles :walls, count: 2
        slots.fill_from_copy(&routine)
      end
    end.unpacking(release: VBlank::Original::Release.from("Test", { "sha1" => SHA1, "size" => COPY_SIZE }))
    unpacking.with(copy_bytes: "\0".b * COPY_SIZE)
  end

  def test_a_routine_that_never_waits_for_a_frame_is_stopped
    Dir.mktmpdir do |folder|
      unpacking = unpacking_of(folder) do |_copy, pack|
        while pack[:walls][0] >= 0
          pack[:walls][1] = 1
        end
      end

      refused = assert_raises(ArgumentError) { unpacking.run_as_ruby(frames: 10, stuck_after: STUCK_AFTER_SECONDS) }

      assert_match "did not wait for a frame", refused.message
    end
  end

  # The Ruby run keeps the copy and the pack as bytes, not a number a byte, and gives the pack back
  # as bytes: what it wrote is the copy byte for byte, the high bytes too (read back signed inside the
  # game, 0x82 is -126), and the same pack the interpreter writes.
  def test_the_pack_played_as_ruby_is_the_copy_byte_for_byte_as_the_interpreter_writes_it
    Dir.mktmpdir do |folder|
      copied = 64
      unpacking = unpacking_of(folder) do |copy, pack|
        repeat(copied) { |at| pack[:walls][at] = copy.byte(at) }
      end
      copy = Array.new(COPY_SIZE) { |at| ((at * 37) + 120) & 0xFF }.pack("C*")
      unpacking = unpacking.with(copy_bytes: copy)

      as_ruby = unpacking.slot_bytes_in(unpacking.run_as_ruby(frames: 10))
      on_interpreter = unpacking.slot_bytes_in(unpacking.run_on(Reference.new, frames: 10))

      assert_equal copy.byteslice(0, copied).bytes, as_ruby.fetch(:walls).bytes
      assert_equal on_interpreter.fetch(:walls).bytes, as_ruby.fetch(:walls).bytes
    end
  end

  # A LONG ROUTINE PLAYS IN A RACTOR, whose stack is small, as the all-in-one build in a test's
  # Ractor and a shell's background unpacking play it. LONG_ROUTINE_COPIES copies written out, each a
  # word read whose answer places a byte read, are thousands of statements; a loop of copy reads at
  # the end writes the tiles over what they wrote, so the slot is the copy's tiles.
  LONG_ROUTINE_COPIES = 500

  def test_a_long_routine_ending_in_a_loop_of_copy_reads_plays_in_a_ractor
    Dir.mktmpdir do |folder|
      unpacking = unpacking_of(folder) do |copy, pack|
        LONG_ROUTINE_COPIES.times do |n|
          at = copy.word(0x10 + ((n * 4) % 0x100))
          count = copy.byte((at & 0xFF) + (n % 64))
          count = 12 if count > 12
          pack[:walls][n % 64] = count
        end
        repeat(TILE_BYTES.bytesize) { |at| pack[:walls][at] = copy.byte(TILES_AT + at) }
      end
      # Handed over as a copy: the lowering keeps notes on the program as it reads it, so it cannot be frozen.
      walls = Ractor.new(unpacking.with(copy_bytes: COPY)) do |routine|
        routine.slot_bytes_in(routine.run_as_ruby(frames: 10_000)).fetch(:walls)
      end.value

      assert_equal TILE_BYTES.bytes, walls.bytes
    end
  end

  # The watchdog ends with the run: a routine that waits and ends gets to its end, and nothing is
  # raised in the test after it.
  def test_a_routine_that_waits_for_frames_gets_to_its_end
    Dir.mktmpdir do |folder|
      unpacking = unpacking_of(folder) { |_copy, _pack| 6.times { wait_vblank } }

      ran = unpacking.run_as_ruby(frames: 10, stuck_after: STUCK_AFTER_SECONDS)
      sleep STUCK_AFTER_SECONDS * 2

      assert unpacking.finished_in?(ran)
    end
  end
end
