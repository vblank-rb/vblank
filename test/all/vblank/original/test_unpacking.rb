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
