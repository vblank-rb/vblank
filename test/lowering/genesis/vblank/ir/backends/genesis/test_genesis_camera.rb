# frozen_string_literal: true

require "test_helper"

# The camera on a Genesis: the window over a painted picture is the plane that shows it scrolled, in the
# blank. Each test plays a game on the cartridge and the interpreter together (Genesis::CheckedRun).
class TestGenesisCamera < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  def test_a_window_swept_across_and_down_shows_what_the_interpreter_shows_pass_for_pass
    program = program_of do
      screen :bitmap
      clear_screen :blue
      fill_rect 100, 70, 40, 20, :red
      fill_rect 0, 0, 16, 16, :green
      step = 0
      game_loop do
        step += 1
        camera (step * 7) - 150, step - 20
      end
    end
    run = Genesis::CheckedRun.new.run(program, frames: 40)

    assert_equal [(40 * 7) - 150, 40 - 20], [run.screen.camera_x, run.screen.camera_y]
  end

  def test_a_window_past_what_the_plane_can_show_is_held_at_the_edge
    program = program_of do
      screen :bitmap
      clear_screen :blue
      camera 900, -900
      halt
    end
    run = Genesis::CheckedRun.new.run(program, frames: 3) # the interpreter shows the backdrop all over; the plane cannot

    assert_equal [192, -32], [run.screen.camera_x, run.screen.camera_y]
  rescue VBlank::IR::Backends::RunComparison::Disagreement => e
    # The picture differs where the interpreter has nothing to show and the plane would come round: said, not hidden.
    assert_match(/picture differs/, e.message)
  end

  def test_a_camera_on_a_tiled_screen_is_refused_in_words
    error = assert_raises(Genesis::Lowering::NotMadeYet) do
      Genesis.new.build(program_of do
        screen :tiled
        image(:dot, "#" => :red) { "##\n##" }
        sprite :dot, at: [10, 10]
        game_loop { camera 4, 0 }
      end)
    end

    assert_match(/camera on a tiled screen/, error.message)
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
