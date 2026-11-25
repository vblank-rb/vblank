# frozen_string_literal: true

require "test_helper"

# More than a bank of recordings at power-on. The Super Nintendo's sound chip plays recordings only
# from its own 64K of memory, and what a game keeps there for all of its life goes across at
# power-on. A cartridge bank holds 32K, so recordings of more than that come from more than one
# bank. The checked run holds every pass to the interpreter; the chip's memory (CheckedRun#apu_ram)
# says the whole recording arrived.
class TestSNESPowerOnRecordings < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Samples = SNES::Samples

  # A recording of 72000 samples, 40500 bytes in the chip's format: more than one bank of the
  # cartridge, well inside the chip's memory. A ramp that never repeats inside a block of the chip's
  # format, so a piece sent from the wrong place shows in the bytes.
  LENGTH = 72_000
  ROAR = Array.new(LENGTH) { |i| ((i * 7) % 200) - 100 }.pack("c*")
  STARTS = 3 # The pass the roar plays on

  private def game(roar = ROAR)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      roar_sound = sample :roar, pcm: roar, rate: 32_000
      step = var :step, 0
      game_loop do
        step += 1
        roar_sound.play(loop: true) if step == STARTS
      end
    end
    b.finalize_program
    b.program
  end

  private def kept(pcm) = Samples.recording(pcm, LENGTH).first

  def test_a_recording_of_more_than_a_bank_goes_across_whole_at_power_on
    run = SNES::CheckedRun.new.run(game, frames: STARTS + 3)

    assert_equal %i[roar], run.active_samples
    assert_operator kept(ROAR).size, :>, 32 * 1024
    assert run.apu_ram.include?(kept(ROAR).pack("C*")), "the whole roar is not in the chip's memory"
  end

  # Recordings that do not fit in the chip's memory beside its program are refused in plain words,
  # naming the sound memory.
  def test_recordings_more_than_the_chip_holds_are_refused
    error = assert_raises(VBlank::BuildError) { SNES.new.build(game(ROAR * 2)) }

    assert_match "sound memory", error.message
  end
end
