# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Sega Genesis: both cartridges in Genesis Plus GX.
class TestHeardAlikeOnTheGenesis < Minitest::Test
  include HeardVoiceTests

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

  # Choosing opens the core again, which would throw away a state put back: chosen first, the voices
  # are kept as the state loads (Genesis Plus GX keeps them in its settings, not its state).
  def test_the_voices_heard_are_chosen_before_a_state_is_loaded
    Dir.mktmpdir("states") do |folder|
      state = File.join(folder, "tune.state")
      played = VBlank::Diagnostics::Verifier.new(tune_game, frames: 0)
      played.step(START + 30).save_state(state)
      loaded = VBlank::Diagnostics::Verifier.new(tune_game, frames: 0).load_state(state)

      late = assert_raises(ArgumentError) { loaded.hearing(only: [:noise]) }
      assert_match "before the first frame", late.message
      chosen = VBlank::Diagnostics::Verifier.new(tune_game, frames: 0)
      chosen.hearing(only: [:noise]).load_state(state).step(10)

      assert_operator chosen.loudest_by_frame.last(5).max * 4, :<, played.step(10).loudest_by_frame.last(5).max,
                      "the noise voice alone, not the tune"
    ensure
      played&.close
      loaded&.close
      chosen&.close
    end
  end
end
