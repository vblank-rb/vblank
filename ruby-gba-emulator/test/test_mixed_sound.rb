# frozen_string_literal: true

require "test_helper"

# Tests for Core#mixed_sound_start and #mixed_sound_finish — the console's own mix of its voices,
# every sample, at the console's mixing rate and before anything changes the rate for a speaker.
class TestRubyGBAEmulatorMixedSound < Minitest::Test
  include RubyGBAEmulatorTestSupport

  # The console mixes two samples every 1,024 cycles, 32,768 a second, and a frame is 280,896
  # cycles: 274 or 275 of those stretches, so 548 or 550 samples.
  SAMPLES_A_FRAME = [548, 550].freeze

  def test_a_frame_of_mixed_sound_is_the_mixing_rate_times_a_frame
    core = RubyGBAEmulator::Core.new(recording_rom)
    3.times { core.run_frame }
    core.mixed_sound_start
    core.run_frame
    samples = core.mixed_sound_finish.unpack("s<*")

    assert_includes SAMPLES_A_FRAME, samples.size / 2
  ensure
    core&.destroy
  end

  def test_a_game_playing_a_recording_mixes_sound_and_a_quiet_one_does_not
    loud = mixed_frames(recording_rom, 10)
    quiet = mixed_frames(red_rom, 10)

    assert(loud.any?(&:nonzero?), "a recording on a loop is heard")
    assert(quiet.all?(&:zero?), "a game that plays nothing mixes silence")
  end

  def test_nothing_is_kept_when_nothing_was_asked_for
    core = RubyGBAEmulator::Core.new(recording_rom)
    core.run_frame

    assert_equal "", core.mixed_sound_finish
  ensure
    core&.destroy
  end

  private

  def mixed_frames(path, frames)
    core = RubyGBAEmulator::Core.new(path)
    core.mixed_sound_start
    frames.times { core.run_frame }
    core.mixed_sound_finish.unpack("s<*")
  ensure
    core&.destroy
  end

  def recording_rom
    ramp = ((-100..100).step(4).to_a + (-100..100).step(4).to_a.reverse)
    build_rom("MIXED", code: "MIXD") do
      screen :bitmap
      clear_screen :black
      tone = sample :ramp, pcm: ramp, rate: 8192
      tone.play(loop: true)
      game_loop {}
    end
  end
end
