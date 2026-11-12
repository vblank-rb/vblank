# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# RECORDINGS WITH THE SAME SAMPLES ARE KEPT ONCE IN A DESKTOP PROGRAM. Each recording's numbers say
# where its samples start in the one array of them all, so recordings alike start at the same place
# and the array holds those samples once. Here the C is the contract, so the tests read it; the
# JavaScript and Ruby builds print the same tables.
class TestNativeEqualRecordings < Minitest::Test
  include EqualRecordingGames

  Native = VBlank::IR::Backends::Native

  # How many samples the program's array of them holds.
  private def samples_held(**game)
    c = Native.new.lower(recordings_game(plays: %i[first second third], **game))
    c[/rg_game_recording_samples\[(\d+)\]/, 1].to_i
  end

  def test_three_recordings_alike_are_held_once
    assert_equal RECORDING.size, samples_held
  end

  def test_recordings_one_sample_apart_are_held_apart
    assert_equal RECORDING.size * 2, samples_held(declared: { second: { pcm: NEARLY } })
  end

  # The rate is how fast a voice steps through the samples, and no part of them.
  def test_one_recording_at_two_rates_is_held_once
    assert_equal RECORDING.size, samples_held(declared: { second: { rate: RATE / 2 } })
  end
end
