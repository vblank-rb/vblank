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

  def test_a_window_at_the_edge_of_what_the_plane_can_show_agrees_with_the_interpreter
    program = program_of do
      screen :bitmap
      clear_screen :blue
      camera 192, -32
      game_loop { nil }
    end
    run = Genesis::CheckedRun.new.run(program, frames: 3)

    assert_equal [192, -32], [run.screen.camera_x, run.screen.camera_y]
  end

  # The interpreter shows the backdrop out there and the plane would come round to the picture, so the
  # cartridge stops rather than show the wrong rows.
  def test_a_window_past_what_the_plane_can_show_stops_the_game_in_words
    [[0, 64], [193, 0], [-193, 0], [0, -33]].each do |x, y|
      program = program_of do
        screen :bitmap
        clear_screen :blue
        camera x, y
        game_loop { nil }
      end
      error = assert_raises(VBlank::IR::Backends::RunComparison::CannotAnswer) { Genesis::HeadlessRun.new.run(program, frames: 3) }

      assert_match(/moved the camera past 192 pixels across or 32 down/, error.message)
    end
  end

  # On a tiled screen the camera moves the planes' scroll and the sprites' places together, every
  # way. The checked run compares the picture with the interpreter's on every pass.
  def test_a_camera_on_a_tiled_screen_agrees_with_the_interpreter_pass_for_pass
    Genesis::CheckedRun.new.run(program_of do
      screen :tiled
      image(:stripe, "#" => :red, "." => :blue) { (["####...."] * 8).join("\n") }
      tiles :ground, "#" => :stripe
      background :field, tiles: :ground, map: (["#" * 32] * 20)
      image(:dot, "#" => :green) { (["########"] * 8).join("\n") }
      sprite :dot, at: [10, 10]
      step = 0
      game_loop do
        step += 1
        camera step - 5, 5 - step
      end
    end, frames: 12)

    pass # the checked run raises at the first pass the two pictures differ
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
