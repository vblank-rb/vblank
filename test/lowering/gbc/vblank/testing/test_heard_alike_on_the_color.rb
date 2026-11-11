# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Game Boy Color: both cartridges in libmgba.
class TestHeardAlikeOnTheColor < Minitest::Test
  include HeardAlikeTests

  private def console = :gbc

  # The Color's speaker is heard settling for a few frames after power-on, on any cartridge.
  private def alike_settings = STRICT.merge(lead_ins: [past_the_power_on_click, past_the_power_on_click])

  # A square note's loudest sample changes from frame to frame on the Color, with where in its wave
  # each frame's samples begin. So a tune a frame later or a note longer has another average level,
  # though each note is as loud.
  private def moved_tune_settings = alike_settings.merge(level_share_apart: 0.1)

  def test_from_power_on_the_click_is_the_first_sound_heard
    compared = VBlank::Playthroughs::HeardComparison.play(listen, tune_game, tune_game, **STRICT)

    assert_predicate compared, :alike?
    assert_equal 1, compared.first.first_heard, "the speaker settling, not the tune"
  end
end
