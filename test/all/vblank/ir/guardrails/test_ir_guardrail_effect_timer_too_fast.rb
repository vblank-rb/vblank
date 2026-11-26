# frozen_string_literal: true

require "test_helper"

# Sound effects on a timer play each tick of a frame as a pass over the effects, so one frame can
# hold IR::Tunes::MOST_TICKS_A_FRAME ticks at most. The build stops and says the rate.
class TestEffectTimerTooFastGuardrail < Minitest::Test
  include VBlank::IR::Build

  Check = VBlank::IR::Guardrails::Checks::EffectTimerTooFast

  private def game(ticks_a_second)
    program(song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: ticks_a_second),
            sound_effect_list(:sfx, [:"sfx.a"]))
  end

  # The ticks a second that give one of the console's frames exactly +ticks+.
  private def ticks_a_frame(ticks) = ticks / game(Rational(50)).described_console.frame_seconds

  def test_a_timer_with_more_ticks_than_a_frame_holds_stops_the_build
    findings = Check.new.detect(game(Rational(1000)))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/8 ticks at most/, findings.first.message)
    assert_match(/1000 times a second/, findings.first.message)
  end

  def test_a_timer_of_several_ticks_a_frame_is_quiet
    [60, 120, 240, 400].each { |rate| assert_empty Check.new.detect(game(Rational(rate))), "#{rate} a second" }
  end

  def test_eight_ticks_a_frame_is_quiet_and_a_little_more_is_not
    assert_empty Check.new.detect(game(ticks_a_frame(8)))
    refute_empty Check.new.detect(game(ticks_a_frame(Rational(81, 10))))
  end

  def test_a_tick_longer_than_a_frame_is_quiet
    assert_empty Check.new.detect(game(Rational(50)))
  end

  # On a driver's own interrupt each interrupt is a pass, so the interrupts are what a frame holds.
  def test_a_drivers_interrupt_with_more_than_a_frame_holds_stops_the_build
    fast = program(song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: Rational(50), interrupt_rate: Rational(1000)),
                   sound_effect_list(:sfx, [:"sfx.a"]))
    slow = program(song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: Rational(50), interrupt_rate: Rational(250, 3)),
                   sound_effect_list(:sfx, [:"sfx.a"]))
    findings = Check.new.detect(fast)

    assert_equal 1, findings.length
    assert_match(/interrupts_per_second/, findings.first.message)
    assert_empty Check.new.detect(slow)
  end

  def test_effects_counted_in_frames_are_quiet
    assert_empty Check.new.detect(program(song(:"sfx.a", total_frames: 4, events: [[0, 880]]), sound_effect_list(:sfx, [:"sfx.a"])))
  end
end
