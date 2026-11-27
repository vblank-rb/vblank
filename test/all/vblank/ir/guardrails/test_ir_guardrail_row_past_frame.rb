# frozen_string_literal: true

require "test_helper"

# A request is sent at a row in the pass that asks for it, so a row past the frame is refused.
class TestRowPastFrameGuardrail < Minitest::Test
  include VBlank::IR::Build

  Check = VBlank::IR::Guardrails::Checks::RowPastFrame

  private def game(rows)
    effect = song(:"sfx.a", total_frames: 4, events: [[0, 880]], timer_rate: Rational(50), interrupt_rate: Rational(250, 3))
    program(effect, sound_effect_list(:sfx, [:"sfx.a"]), play_sound_effect(:sfx, which: 0, sent_after_rows: rows)).tap do |made|
      made.console = :snes
    end
  end

  def test_a_row_at_the_frames_end_is_refused
    findings = Check.new.detect(game(262))

    assert_equal 1, findings.length
    assert findings.first.error?
    assert_match(/262 rows/, findings.first.message)
  end

  def test_a_row_in_the_frame_is_quiet
    assert_empty Check.new.detect(game(261))
  end
end
