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
end
