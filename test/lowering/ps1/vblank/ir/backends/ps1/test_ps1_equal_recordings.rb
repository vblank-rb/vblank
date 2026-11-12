# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# RECORDINGS WITH THE SAME SAMPLES ARE KEPT ONCE IN THE PLAYSTATION'S SOUND MEMORY. A play's row carries
# how fast its voice reads them, how loud and which recording it is to the game, so the samples are
# needed once however many names play them.
class TestPS1EqualRecordings < Minitest::Test
  include EqualRecordingGames

  PS1 = VBlank::IR::Backends::PS1

  # A recording as sound memory keeps it, looping round from its start.
  private def kept(samples)
    data, from = PS1::SoundMemory.recording_samples(samples.map { |sample| sample << 8 }, samples.size)
    PS1::ADPCM.encode(data, loop: true, loop_from: from)
  end

  private def sound_memory_of(**game)
    run = PS1::CheckedRun.new.run(recordings_game(plays: %i[first second third], console: :ps1, **game), frames: 6)
    [run, run.rom.built.sound_voicing.memory.bytes]
  end

  def test_three_recordings_alike_are_in_sound_memory_once
    run, bytes = sound_memory_of

    assert_equal 1, copies_held(bytes, kept(RECORDING))
    assert_equal %i[first second third], run.active_samples, "each sounds under its own name"
  end

  def test_recordings_one_sample_apart_are_kept_apart
    _, bytes = sound_memory_of(declared: { second: { pcm: NEARLY } })

    assert_equal [1, 1], [copies_held(bytes, kept(RECORDING)), copies_held(bytes, kept(NEARLY))]
  end

  # The rate is how fast a voice reads the samples, and no part of them.
  def test_one_recording_at_two_rates_is_kept_once
    _, bytes = sound_memory_of(declared: { second: { rate: 11_000 } })

    assert_equal 1, copies_held(bytes, kept(RECORDING))
  end
end
