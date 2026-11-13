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
end
