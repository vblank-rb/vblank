# frozen_string_literal: true

require "test_helper"

# A PLAYSTATION PROGRAM'S READER HAS NO SAMPLES TO GIVE YET: its emulator gem counts the samples
# Beetle PSX makes and keeps none. Asked what the program put out, it says so, where an empty
# frame would read as a program that makes no sound.
class TestPS1HeardSound < Minitest::Test
  private def reader
    program = VBlank.build("QUIET", console: :ps1, out: nil, err: nil) { game_loop {} }
    VBlank::Diagnostics::Verifier.new(program, frames: 0)
  end

  def test_the_last_frames_sound_is_refused_saying_the_emulator_gives_no_samples
    error = assert_raises(ArgumentError) { reader.last_frame_sound }

    assert_match "PlayStation", error.message
    assert_match "no sound samples yet", error.message
  end

  def test_the_loudest_sample_of_each_frame_is_refused_the_same_way
    assert_match "no sound samples yet", assert_raises(ArgumentError) { reader.loudest_by_frame }.message
  end
end
