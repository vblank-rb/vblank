# frozen_string_literal: true

require "test_helper"
require "heard_alike_tests"

# A port's heard sound held to its original's, on the Advance: both cartridges in libmgba.
class TestHeardAlike < Minitest::Test
  include HeardAlikeTests

  private def console = :gba

  def test_a_lead_in_for_each_is_not_counted
    late = 7
    led_in = VBlank.playthrough("the late one's extra frames") { wait frames: late }
    as_a_file(tune_game(starts: START + late)) do |path|
      failure = assert_raises(Minitest::Assertion) { assert_heard_alike tune_game, path, listen, **alike_settings }
      assert_match "first heard on different frames", failure.message

      assert_heard_alike tune_game, path, listen, **alike_settings, lead_ins: [nil, led_in]
    end
  end

  def test_a_setting_that_makes_no_sense_is_refused_before_anything_is_played
    settings = STRICT.merge(level_share_apart: 10)

    error = assert_raises(ArgumentError) { assert_heard_alike "no.gba", "none.gba", listen, **settings }

    assert_match "level_share_apart", error.message
    assert_match "0 to 1", error.message
  end

  def test_a_setting_left_out_is_refused
    assert_raises(ArgumentError) { assert_heard_alike "no.gba", "none.gba", listen, heard_above: 0 }
  end
end
