# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Sega Genesis: both cartridges in Genesis Plus GX.
class TestHeardAlikeOnTheGenesis < Minitest::Test
  include HeardAlikeTests

  private def console = :genesis

  # Genesis Plus GX's output is heard settling for a few frames after power-on, on any cartridge.
  private def alike_settings = STRICT.merge(lead_ins: [past_the_power_on_click, past_the_power_on_click])

  # The core takes which voices it plays as it loads the cartridge, so a reader chooses them before
  # the first frame, by the names the Genesis's voices have.
  def test_the_voices_heard_are_chosen_before_the_first_frame
    reader = VBlank::Diagnostics::Verifier.new(tune_game, frames: 0)
    assert_includes reader.channels, :fm1
    assert_includes reader.channels, :square1
    unknown = assert_raises(ArgumentError) { reader.hearing(only: [:wave]) }
    assert_match "no voice wave", unknown.message
    reader.hearing(only: [:noise]).step(START + 30)
    every_voice = VBlank::Diagnostics::Verifier.new(tune_game, frames: 0).step(START + 30)

    # The noise voice alone hears the power-on settling and not the tune, which is on another voice.
    assert_operator reader.loudest_by_frame.max * 4, :<, every_voice.loudest_by_frame.max
    late = assert_raises(ArgumentError) { reader.hearing(only: [:square1]) }
    assert_match "before the first frame", late.message
  ensure
    reader&.close
    every_voice&.close
  end
end
