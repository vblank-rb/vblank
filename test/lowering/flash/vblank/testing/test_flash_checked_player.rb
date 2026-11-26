# frozen_string_literal: true

require "test_helper"

# Only what the Flash runtime lacks is a skip. A test that asks the run something it never answers fails, as it does
# on the JavaScript and native runs.
class TestFlashCheckedPlayer < Minitest::Test
  def test_a_question_the_run_never_answers_fails_the_test
    program = VBlank.game("small", consoles: %i[gba]) { game_loop { clear_screen :black } }.program(console: :gba)
    player = VBlank::Testing::FlashCheckedPlayer.new
    player.each_vblank { player.frame }

    assert_raises(VBlank::IR::Backends::RunComparison::CannotAnswer) { player.run(program, frames: 2) }
  end
end
