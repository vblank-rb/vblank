# frozen_string_literal: true

require "test_helper"

# A PlayStation program's reader hands over the samples Beetle PSX mixed each frame, as every other
# console's does, and no voice alone: Beetle has no setting to leave one out.
class TestPS1HeardSound < Minitest::Test
  private def quiet_program = VBlank.build("QUIET", console: :ps1, out: nil, err: nil) { game_loop {} }

  private def reader = VBlank::Diagnostics::Verifier.new(quiet_program, frames: 0)

  # A frame holds the sound chip's 44,100 pairs a second over one of the console's frames, both
  # speakers, and a program that makes no sound puts out silence.
  def test_each_frame_hands_over_the_samples_the_emulator_mixed
    played = reader.step(10)
    pairs = VBlank::Diagnostics::SoundRecording::CARTRIDGE_RATES.fetch(:ps1) * VBlank::Console.described(:ps1).frame_seconds

    assert_in_delta 2 * pairs, played.last_frame_sound.samples.size, 4
    assert_equal [0] * 10, played.loudest_by_frame
  ensure
    played&.close
  end

  # No voice can be heard alone, so a comparison told which voices to hear refuses before it plays.
  def test_a_comparison_of_chosen_voices_is_refused_saying_none_plays_alone
    listen = VBlank.playthrough("listen") { wait frames: 4 }
    error = assert_raises(ArgumentError) do
      VBlank::Playthroughs::HeardComparison.play(listen, quiet_program, quiet_program, heard_above: 0, first_heard_frames_apart: 0,
                                                 level_share_apart: 0, ending_frames_apart: 0, hearing: [[:voice0], [:voice0]])
    end

    assert_match "cannot play a voice alone", error.message
    assert_empty reader.channels
  end
end
