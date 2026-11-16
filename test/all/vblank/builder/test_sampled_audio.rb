# frozen_string_literal: true

require "test_helper"

# `sample` and `instrument`'s own settings, written in the game. A length read from a data pack is
# held rather than refused (test/pack_sound_tests.rb); one the game writes itself is a mistake.
class TestSampledAudio < Minitest::Test
  def test_a_length_written_outside_the_recording_is_a_friendly_error
    [0, 5].each do |length|
      b = VBlank::Builder.new
      error = assert_raises(ArgumentError) do
        b.instance_eval { sample :bang, pcm: [10, -10, 20, -20], length: length }
      end

      assert_includes error.message, "a whole number from 1 to 4"
    end
  end

  # A rate or a hold read from the pack is held as the shell holds it (test/pack_sound_tests.rb);
  # one the game writes itself is a mistake.
  def test_a_rate_written_below_one_is_a_friendly_error
    b = VBlank::Builder.new
    error = assert_raises(ArgumentError) { b.instance_eval { sample :bang, pcm: [10, -10, 20, -20], rate: 0 } }

    assert_includes error.message, "positive rate"
  end

  def test_a_hold_written_outside_the_recording_is_a_friendly_error
    [-1, 4].each do |holds_from|
      b = VBlank::Builder.new
      error = assert_raises(ArgumentError) do
        b.instance_eval { sample :bang, pcm: [10, -10, 20, -20], holds_from: holds_from }
      end

      assert_includes error.message, "4 samples long"
    end
  end

  # `bits:` says how deep `pcm:` is (test/full_depth_sound_tests.rb plays one of sixteen).
  def test_a_depth_other_than_8_or_16_is_a_friendly_error
    error = assert_raises(ArgumentError) { VBlank::Builder.new.instance_eval { sample :bang, pcm: [10, -10], bits: 12 } }

    assert_includes error.message, "bits: 8 or bits: 16"
  end

  def test_a_depth_without_pcm_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      VBlank::Builder.new.instance_eval { sample :bang, from: "bang.wav", bits: 16 }
    end

    assert_includes error.message, "remove bits:"
  end

  def test_a_16_bit_sample_outside_sixteen_bits_is_a_friendly_error
    error = assert_raises(ArgumentError) { VBlank::Builder.new.instance_eval { sample :bang, pcm: [10, 40_000], bits: 16 } }

    assert_includes error.message, "-32768..32767"
  end
end
