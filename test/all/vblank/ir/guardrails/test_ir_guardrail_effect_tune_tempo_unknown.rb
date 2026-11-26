# frozen_string_literal: true

require "test_helper"

# Sound effects on the tune's tempo add the playing song's tempo on each interrupt, so a song with no
# one tempo would leave them still while it plays. The build stops and names the song.
class TestEffectTuneTempoUnknownGuardrail < Minitest::Test
  include VBlank::IR::Build

  Check = VBlank::IR::Guardrails::Checks::EffectTuneTempoUnknown

  private def game(tune_tick_rate, on_tune_tempo: true)
    program(song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: Rational(50), interrupt_rate: Rational(250, 3),
                           on_tune_tempo: on_tune_tempo),
            song(:tune, total_frames: 4, events: [[0, 440]], tick_rate: tune_tick_rate),
            sound_effect_list(:sfx, [:"sfx.a"]))
  end

  def test_a_song_with_no_one_tempo_stops_the_build
    findings = Check.new.detect(game(nil))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/:tune/, findings.first.message)
    assert_match(/on_tune_tempo/, findings.first.message)
  end

  def test_a_song_with_one_tempo_is_quiet
    assert_empty Check.new.detect(game(Rational(50)))
  end

  def test_effects_with_a_tempo_of_their_own_are_quiet
    assert_empty Check.new.detect(game(nil, on_tune_tempo: nil))
  end
end
