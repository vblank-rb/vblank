# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Game Boy Color: both cartridges in libmgba.
class TestHeardAlikeOnTheColor < Minitest::Test
  include HeardVoiceTests

  private def console = :gbc

  # The Color's speaker is heard settling for a few frames after power-on, on any cartridge.
  #
  # And after a note ends: the square voice stops wherever its wave is, and the speaker settles from
  # there over a few frames, its loudest sample anywhere from nought to about 550 by that place. Where
  # the wave stands at the note's end moves with the frame the tune started on, so a level of 400
  # read one ending as silent at once and another five frames later. Every note here is heard well
  # over 6000, so a frame is heard above 1000.
  private def alike_settings = STRICT.merge(heard_above: 1000, lead_ins: [past_the_power_on_click, past_the_power_on_click])

  # A few frames after a square voice is switched off, mGBA's speaker can step and settle again, as
  # loud as a note for a frame, with no write to the sound chip on that frame: at some starts of the
  # tune the voice goes off on one frame and the speaker is heard again four frames later. So a tune's
  # end is heard up to six frames from its last note's here.
  private def ending_heard_within = 7

  # Where a last note starts to fall away is its last frame at least half its loudest frame's level
  # (Playthroughs::HeardSound#fall_starts), and on the Color that loudest frame is wherever the
  # square wave's peaks fell, twice and more a frame's usual level: a tune a frame later reads its
  # fall as two frames or seven by that alone. The last frames heard stay one apart, which the test
  # below holds.
  private def frame_late_endings_apart = 6

  def test_a_tune_a_frame_late_is_last_heard_a_frame_later
    as_a_file(tune_game(starts: START + 1)) do |path|
      compared = VBlank::Playthroughs::HeardComparison.play(listen, tune_game, path, **moved_tune_settings)

      assert_equal compared.first.last_heard + 1, compared.second.last_heard
    end
  end

  # A square note's loudest sample changes from frame to frame on the Color, with where in its wave
  # each frame's samples begin. So a tune a frame later or a note longer has another average level,
  # though each note is as loud.
  private def moved_tune_settings = alike_settings.merge(level_share_apart: 0.1)

  # The same note on the other square voice starts its wave at another place and falls silent from
  # another, so its loudest samples and its ending move as a tune a frame later does.
  private def moved_voice_settings = moved_tune_settings.merge(ending_frames_apart: frame_late_endings_apart)

  def test_from_power_on_the_click_is_the_first_sound_heard
    compared = VBlank::Playthroughs::HeardComparison.play(listen, tune_game, tune_game, **STRICT)

    assert_predicate compared, :alike?
    assert_equal 1, compared.first.first_heard, "the speaker settling, not the tune"
  end
end
