# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# RECORDINGS WITH THE SAME SAMPLES ARE KEPT ONCE IN A GENESIS CARTRIDGE. A play's row of the table
# carries how fast it is read, where it goes back to and which recording it is to the game, so
# the bytes the DAC takes are needed once however many names play them.
class TestGenesisEqualRecordings < Minitest::Test
  include EqualRecordingGames

  Genesis = VBlank::IR::Backends::Genesis

  # A recording as the cartridge keeps it: the bytes the DAC takes, the middle at 128.
  private def kept(samples) = samples.map { |sample| sample + 128 }.pack("C*")

  private def cartridge_of(**game)
    Genesis::CheckedRun.new.run(recordings_game(plays: %i[first second third], console: :genesis, **game), frames: 6).rom.bytes
  end

  def test_three_recordings_alike_are_in_the_cartridge_once
    assert_equal 1, copies_held(cartridge_of, kept(RECORDING))
  end

  def test_recordings_one_sample_apart_are_kept_apart
    cartridge = cartridge_of(declared: { second: { pcm: NEARLY } })

    assert_equal [1, 1], [copies_held(cartridge, kept(RECORDING)), copies_held(cartridge, kept(NEARLY))]
  end

  # The rate is how fast a play's row reads the bytes, and no part of them.
  def test_one_recording_at_two_rates_is_kept_once
    assert_equal 1, copies_held(cartridge_of(declared: { second: { rate: 11_000 } }), kept(RECORDING))
  end
end
