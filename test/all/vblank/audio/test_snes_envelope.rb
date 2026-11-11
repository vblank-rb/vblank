# frozen_string_literal: true

require "test_helper"

# THE SUPER NINTENDO SOUND CHIP'S OWN ENVELOPE SETTINGS (Audio::SNESEnvelope), and the ordinary
# Audio::Envelope nearest each, which is what the interpreter and every other console play. The
# answer key is the chip's documented arithmetic: its steps and the samples each rate waits
# (fullsnes, "SNES APU DSP ADSR/Gain Envelope"), worked out by hand in each test's comment.
class TestSNESEnvelope < Minitest::Test
  Envelope = VBlank::Audio::Envelope
  SNESEnvelope = VBlank::Audio::SNESEnvelope

  private def closest(**bytes) = SNESEnvelope.new(**bytes).closest_envelope

  # How many frames +envelope+ takes to climb to full.
  private def frames_to_full(envelope) = (Envelope::FULL / envelope.attack.to_f).ceil

  # --- ADSR ---

  def test_the_fastest_attack_held_at_the_top_is_a_plain_note
    # Attack 15 steps 1024 a sample, sustain level 7 is the top and sustain rate 0 never steps.
    assert_predicate closest(adsr1: 0x8F, adsr2: 0xE0), :plain?
  end

  def test_a_slow_attack_climbs_over_as_many_frames_as_the_chip_takes
    # Attack 5 is rate 11, a step of 32 every 192 samples: 63 steps to $7E0, 12,096 samples, 23 frames.
    envelope = closest(adsr1: 0x85, adsr2: 0xE0)

    assert_in_delta 23, frames_to_full(envelope), 2
    assert_operator envelope.sustain, :>=, 250, "it holds where the attack left it, near the top"
  end

  def test_a_decay_falls_to_the_sustain_level_and_holds_there
    # Decay 0 is rate 16, a step every 64 samples, each taking a 256th of the level off and one
    # more: half is 151 steps away, 9,664 samples, 18 frames. Sustain level 3 holds at half, $400
    # of $7FF.
    envelope = closest(adsr1: 0x8F, adsr2: 0x60)

    assert_equal Envelope::MOST, envelope.attack
    assert_in_delta 128, envelope.sustain, 3
    assert_in_delta 18, Envelope.frames_to_fall(envelope.decay, Envelope::FULL, envelope.sustain), 3
    assert_equal 0, envelope.release, "a key-off on the chip is over inside a frame"
  end

  def test_a_sustain_rate_falls_on_to_nothing
    # Sustain level 7 skips the decay, and sustain rate 20 steps every 24 samples. A step takes
    # off a 256th of the level and one more, so the level and 256 fall by a 256th together: from
    # $7FF to half of it is 256 * ln(2303 / 1279) steps, 151 of them, 3,624 samples, 7 frames.
    envelope = closest(adsr1: 0x8F, adsr2: 0xF4)

    assert_equal 0, envelope.sustain
    assert_in_delta 7, Envelope.frames_to_fall(envelope.decay, Envelope::FULL, Envelope::FULL / 2), 1
  end

  # --- GAIN, read when ADSR1's top bit is nought ---

  def test_a_direct_gain_at_the_top_is_a_plain_note
    assert_predicate closest(adsr1: 0x00, gain: 0x7F), :plain?
  end

  def test_a_direct_gain_holds_its_level
    # Direct gain $40 holds the level at $400, half of the top.
    envelope = closest(adsr1: 0x00, gain: 0x40)

    assert_equal Envelope::MOST, envelope.attack
    assert_equal 0, envelope.decay, "straight to its level"
    assert_in_delta 128, envelope.sustain, 2
  end

  def test_a_direct_gain_of_nothing_is_silent
    assert_silent_shape closest(adsr1: 0x00, gain: 0x00)
  end

  def test_a_linear_increase_climbs_and_holds_at_the_top
    # Mode 6 at rate 10 steps 32 every 256 samples: 64 steps, 16,384 samples, 31 frames.
    envelope = closest(adsr1: 0x00, gain: 0xCA)

    assert_in_delta 31, frames_to_full(envelope), 2
    assert_equal Envelope::MOST, envelope.sustain
  end

  def test_a_bent_increase_takes_longer_than_a_linear_one_at_the_same_rate
    # Mode 7 steps 32 up to $600 and 8 from there: 48 steps and 64 more against 64 in all.
    bent = closest(adsr1: 0x00, gain: 0xEA)
    linear = closest(adsr1: 0x00, gain: 0xCA)

    assert_operator frames_to_full(bent), :>, frames_to_full(linear)
    assert_equal Envelope::MOST, bent.sustain
  end

  def test_a_decrease_from_key_on_is_silent
    # A key-on starts the chip's level at nothing, and both decrease modes fall from where it is.
    assert_silent_shape closest(adsr1: 0x00, gain: 0x9F) # linear decrease
    assert_silent_shape closest(adsr1: 0x00, gain: 0xBF) # exponential decrease
  end

  private def assert_silent_shape(envelope)
    level = 0
    phase = Envelope::CLIMBING
    60.times { level, phase = envelope.step(level, phase) }

    assert_equal 0, level, "the level never leaves nothing"
    refute_predicate envelope, :plain?
  end

  # --- the bytes themselves ---

  def test_it_keeps_the_three_bytes_it_was_given
    chip = SNESEnvelope.new(adsr1: 0x8E, adsr2: 0xE0, gain: 0x12)

    assert_equal [0x8E, 0xE0, 0x12], [chip.adsr1, chip.adsr2, chip.gain]
  end

  def test_a_byte_out_of_range_is_refused
    error = assert_raises(ArgumentError) { SNESEnvelope.new(adsr1: 0x100) }

    assert_includes error.message, "0 to 255"
  end
end
