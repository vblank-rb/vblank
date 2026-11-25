# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# Recordings with the same samples are kept once in the Advance's cartridge. A voice there names
# its recording by a number kept in its own slot, so each is still told by its own name when the
# voices are read back, and stopping one leaves its twin sounding. What a game can tell on every
# run is in test/all/vblank/builder/test_equal_recordings.rb.
class TestGBAEqualRecordings < Minitest::Test
  include EqualRecordingGames

  FRAMES = 8

  private def cartridge_of(**game)
    assemble_rom(recordings_game(plays: %i[first second third], **game), name: "EQUAL")
  end

  private def bytes_of(samples) = samples.pack("c*")

  def test_three_recordings_alike_are_kept_once_in_the_cartridge
    rom = cartridge_of

    assert_equal 1, copies_held(rom.buffer, bytes_of(RECORDING))
  end

  def test_recordings_one_sample_apart_are_kept_apart
    rom = cartridge_of(declared: { second: { pcm: NEARLY } })

    assert_equal 1, copies_held(rom.buffer, bytes_of(RECORDING))
    assert_equal 1, copies_held(rom.buffer, bytes_of(NEARLY))
  end

  def test_each_voice_is_named_for_its_own_recording
    console = assert_emulator_loads_rom(cartridge_of, frames: FRAMES)

    assert_equal %i[first second third], console.sounding.sort_by { |name| %i[first second third].index(name) }
  end

  def test_stopping_one_recording_leaves_the_ones_alike_it_sounding
    console = assert_emulator_loads_rom(assemble_rom(recordings_game(plays: %i[first second third], stops: :second), name: "EQSTOP"),
                                        frames: FRAMES)

    assert_equal %i[first third], console.sounding.sort_by { |name| %i[first second third].index(name) }
  end
end
