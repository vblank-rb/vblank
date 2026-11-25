# frozen_string_literal: true

require "test_helper"

# A sound effect on a timer starts on the timer's next tick, so a tree that asks one to start where
# it is asked (`this_frame: true`) is refused, however the tree was made.
class TestEffectOnTimerThisFrameGuardrail < Minitest::Test
  include VBlank::IR::Build

  Check = VBlank::IR::Guardrails::Checks::EffectOnTimerThisFrame

  private def game(this_frame:, timer_rate: Rational(50))
    program(song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: timer_rate),
            sound_effect_list(:sfx, [:"sfx.a"]),
            play_sound_effect(:sfx, which: 0, this_frame: this_frame))
  end

  def test_an_effect_on_a_timer_started_this_frame_stops_the_build
    findings = Check.new.detect(game(this_frame: true))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/next tick of the timer/, findings.first.message)
  end

  def test_an_effect_on_a_timer_started_at_its_tick_is_quiet
    assert_empty Check.new.detect(game(this_frame: false))
  end

  def test_an_effect_counted_in_frames_started_this_frame_is_quiet
    assert_empty Check.new.detect(game(this_frame: true, timer_rate: nil))
  end
end
