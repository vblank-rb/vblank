# frozen_string_literal: true

require "test_helper"

# Sound effects on a timer play one tick on a frame at most, so a timer faster than the console's
# frames would lose ticks. The build stops and says the rate.
class TestEffectTickTooShortGuardrail < Minitest::Test
  include VBlank::IR::Build

  Check = VBlank::IR::Guardrails::Checks::EffectTickTooShort

  private def game(ticks_a_second)
    program(song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: ticks_a_second),
            sound_effect_list(:sfx, [:"sfx.a"]))
  end

  def test_a_timer_faster_than_frames_stops_the_build
    findings = Check.new.detect(game(Rational(80)))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/one frame or longer/, findings.first.message)
  end

  def test_a_timer_of_a_frame_or_slower_is_quiet
    assert_empty Check.new.detect(game(Rational(50)))
  end

  def test_effects_counted_in_frames_are_quiet
    assert_empty Check.new.detect(program(song(:"sfx.a", total_frames: 4, events: [[0, 880]]), sound_effect_list(:sfx, [:"sfx.a"])))
  end
end
