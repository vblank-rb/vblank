# frozen_string_literal: true

require "test_helper"

# A RECORDING GIVEN THE SUPER NINTENDO SOUND CHIP'S OWN ENVELOPE BYTES (Builder#sample's
# `envelope:` as an Audio::SNESEnvelope) plays on every console as the ordinary envelope nearest
# them. Here with the bytes that sound a note flat out, whose nearest envelope is no shape at all,
# so every console plays it; bytes that shape a note are test/snes_envelope_tests.rb, on the
# consoles that shape a recording.
class TestSNESEnvelopeRecordings < Minitest::Test
  FLAT_OUT = VBlank::Audio::SNESEnvelope.new(adsr1: 0x00, gain: 0x7F)

  private def recording_game(envelope)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      clip = sample :clip, pcm: [60, -60] * 2000, rate: 8000, envelope: envelope
      clip.play
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  private def heard(program)
    run = game_player.run(program, frames: 6)
    [run.audio, run.active_samples]
  end

  def test_a_recording_given_the_chips_flat_out_gain_plays_as_one_given_no_envelope
    wanted = heard(recording_game(nil))

    assert_equal [:clip], wanted.last
    assert_equal wanted, heard(recording_game(FLAT_OUT))
  end

  def test_anything_but_an_envelope_is_still_refused_in_plain_words
    error = assert_raises(ArgumentError) { recording_game(0x8F) }

    assert_includes error.message, "An envelope is"
  end
end
