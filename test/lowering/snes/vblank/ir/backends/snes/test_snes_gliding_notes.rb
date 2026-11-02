# frozen_string_literal: true

require "test_helper"

# A GLIDING NOTE ON THE SOUND CHIP. The checked run holds where the note has got to against the
# interpreter, but what is heard is the chip's voice, so these read its pitch registers.
class TestSNESGlidingNotes < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  VOICE = 4 << 4 # the first voice recordings play on
  ENVX = 0x8
  ROOT = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(:C4)
  RATE = 16_000
  # Half the chip's own rate at the recording's note: pitch $0800, and an octave up $1000.
  OWN_PITCH = 0x0800

  private def played(notes, frames:)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * RATE, rate: RATE, note: :C4
      sfx = sound_effects :sfx, { chirp: Score.new(parts: [Score::Part.new(plays: :tone, notes: notes)], tempo: 150, ticks_per_beat: 4) }
      passes = var :passes, 0
      game_loop do
        passes += 1
        sfx.play 0 if passes == 2
      end
    end
    b.finalize_program
    SNES::CheckedRun.new.run(b.program, frames: frames)
  end

  private def pitch_of(run)
    dsp = run.dsp_registers
    dsp.getbyte(VOICE + 2) | (dsp.getbyte(VOICE + 3) << 8)
  end

  def test_a_glide_reaches_the_voice_pitch
    notes = [Score::Note.new(at: 0, hz: ROOT), Score::Note.new(at: 3, hz: ROOT * 2, length: 20, glides: true)]

    assert_in_delta OWN_PITCH, pitch_of(played(notes, frames: 10)), 2, "before the glide"
    assert_in_delta OWN_PITCH * 2, pitch_of(played(notes, frames: 30)), 4, "after the glide"
  end

  def test_a_glide_with_nothing_sounding_stays_silent
    run = played([Score::Note.new(at: 3, hz: ROOT * 2, length: 20, glides: true)], frames: 30)

    assert_equal 0, run.dsp_registers.getbyte(VOICE + ENVX)
    assert_empty run.active_samples
  end
end
