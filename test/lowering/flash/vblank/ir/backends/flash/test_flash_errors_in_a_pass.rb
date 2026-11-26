# frozen_string_literal: true

require "test_helper"

# An error the Flash player raises inside a pass (an index past a vector, a null routine) is the game going
# wrong, and the run ends as the C build's does, with the error's words: it is not a warning the next frame
# plays on after.
class TestFlashErrorsInAPass < Minitest::Test
  Flash = VBlank::IR::Backends::Flash

  def test_an_index_past_a_vector_ends_the_run_with_the_error
    error = assert_raises(VBlank::IR::ProgramError) { play(broken: "var rg_broken = rg_game_sines[100000];") }

    assert_match(/range|1125/i, error.message)
  end

  def test_a_null_routine_ends_the_run_with_the_error
    error = assert_raises(VBlank::IR::ProgramError) { play(broken: "var rg_routine:Void -> Void = null; rg_routine();") }

    assert_match(/null|1009|1006/i, error.message)
  end

  private

  # A small game whose main routine starts with +broken+, played for three frames in the harness.
  def play(broken:)
    game = VBlank.game("small", consoles: %i[gba]) do
      game_loop { clear_screen :black }
    end
    program = VBlank::IR::Backends::Computer::CheckedProgram.build(game, console: :gba, err: StringIO.new)
    lowering = Flash::Lowering.new(program)
    text, = lowering.text_and_gaps(Flash::HEADLESS_FUNCTIONS)
    text = text.sub("static function rg_game_main():Int {\n", "static function rg_game_main():Int {\n  #{broken}\n")
    flash = Flash.new
    swf = flash.compile(flash.class_text(lowering, text, Flash::HEADLESS_DRIVER), width: 240, height: 160)
    VBlank::IR::Backends::Computer::ProgramRun.run(VBlank::Diagnostics::FlashPlayer.harness_path, args: [swf, "--headless", "3"],
                                                                                                    input: "0\n0\n0\n", seconds: 30)
  end
end
