# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# RECORDINGS WITH THE SAME SAMPLES ARE KEPT ONCE IN A COLOR CARTRIDGE. A Color keeps a recording as
# the bits its voice is switched by, one for each sample the mix would read of it, so what it keeps
# follows the samples, the rate they were recorded at and the note they are played at. Recordings
# alike in all three read one section of bits; a different rate reads the samples at another
# speed, which is other bits.
class TestGBCEqualRecordings < Minitest::Test
  include EqualRecordingGames

  Clips = VBlank::IR::Backends::GBC::Clips

  # How many sections of bits the game's clips take, past their table.
  private def clip_sections(**game)
    Clips.new(recordings_game(plays: %i[first second third], console: :gbc, **game)).sections.size - 1
  end

  def test_three_recordings_alike_read_one_section_of_bits
    assert_equal 1, clip_sections
  end

  def test_recordings_one_sample_apart_are_kept_apart
    assert_equal 2, clip_sections(declared: { second: { pcm: NEARLY } })
  end

  def test_one_recording_at_two_rates_is_kept_twice
    assert_equal 2, clip_sections(declared: { second: { rate: RATE / 2 } })
  end

  def test_the_cartridge_plays_them_as_the_interpreter_does
    run = VBlank::IR::Backends::GBC::CheckedRun.new.run(recordings_game(plays: %i[first second third], console: :gbc), frames: 8)

    assert_includes run.audio, [:sample, :third]
  end
end
