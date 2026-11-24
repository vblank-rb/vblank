# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the PlayStation: both programs in Beetle PSX,
# whose samples the probe hands out as it does every other console's. Beetle mixes the sound chip's
# 24 voices into one output and has no setting to leave one out, so no voice is heard alone here.
class TestHeardAlikeOnThePlayStation < Minitest::Test
  include HeardAlikeTests

  private def console = :ps1

  private def voices_heard_alone? = false

  # Pitch is held a voice at a time, and no voice plays alone here, so it is refused before anything
  # is played.
  def test_pitch_is_refused_saying_no_voice_plays_alone
    error = assert_raises(ArgumentError) do
      VBlank::Playthroughs::HeardComparison.play(listen, tune_game, tune_game, **alike_settings, pitch_cents_apart: 25)
    end

    assert_match "pitch_cents_apart", error.message
    assert_match "cannot play a voice alone", error.message
  end
end
