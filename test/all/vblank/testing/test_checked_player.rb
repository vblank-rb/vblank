# frozen_string_literal: true

require "test_helper"

# A GAME'S TESTS STOP WHERE ITS BUILD STOPS. Every run's player checks a test's program the way
# VBlank.build checks a game before it makes anything (Testing::BuildChecks), so a slip the build
# refuses in plain words is refused in the same words here, naming the verb and the line, rather
# than reaching a lowering and failing far from the line.
class TestCheckedPlayer < Minitest::Test
  # A sound's loudness is a setting written in the program; a variable there is the author's slip.
  def test_a_game_number_where_a_verb_takes_a_written_one_is_refused_naming_the_verb
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      loudness = var :loudness, 10
      beep 440, volume: loudness
      game_loop { wait_vblank }
    end
    b.finalize_program

    error = assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(b.program, frames: 2) }

    assert_match(/`beep`/, error.message)
    assert_match(/test_checked_player\.rb:\d+/, error.message, "it names the line the author wrote")
    assert_match(/works out as it runs/, error.message)
  end
end
