# frozen_string_literal: true

require "test_helper"

# A sound driver's habit a console's build does not make yet is refused by name, and a request at a row
# in a game whose driver has no wakes is refused, rather than either playing other beats than the
# interpreter.
class TestSoundDriverNotMadeYetGuardrail < Minitest::Test
  include VBlank::IR::Build

  Check = VBlank::IR::Guardrails::Checks::SoundDriverNotMadeYet
  Rows = VBlank::IR::Guardrails::Checks::RowWithoutWakes

  private def game(console, starts_on_tick: false, rows: nil, interrupt_rate: Rational(250, 3))
    effect = song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: Rational(50), interrupt_rate: interrupt_rate,
                            starts_on_tick: starts_on_tick)
    program(effect, sound_effect_list(:sfx, [:"sfx.a"]), play_sound_effect(:sfx, which: 0, sent_after_rows: rows)).tap do |made|
      made.console = console
    end
  end

  def test_a_habit_the_build_does_not_make_is_refused_by_name
    findings = Check.new.detect(game(:gba, starts_on_tick: true))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/on_next_tick/, findings.first.message)
  end

  def test_a_row_the_build_does_not_make_is_refused
    assert_match(/sent_after_rows/, Check.new.detect(game(:gba, rows: 30)).first.message)
  end

  def test_a_game_naming_no_habit_is_quiet
    assert_empty Check.new.detect(game(:gba))
  end

  def test_a_row_with_no_wakes_is_refused
    findings = Rows.new.detect(game(:gba, rows: 30, interrupt_rate: nil))

    assert_equal 1, findings.length
    assert_match(/interrupts_per_second/, findings.first.message)
    assert_empty Rows.new.detect(game(:gba, rows: 30))
  end
end
