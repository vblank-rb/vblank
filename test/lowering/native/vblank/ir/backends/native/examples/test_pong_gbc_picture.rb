# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/pong_gbc").to_s

# examples/pong_gbc.rb built for the desktop as the Color's game shows the interpreter's picture
# pixel for pixel, frame by frame, over a recorded run: the tiled title and its menu, START, and a
# rally on the painted screen with the paddle moved up and down. Its sound log matches entry for
# entry too.
class TestPongGBCPicture < Minitest::Test
  include NativeComparison

  # The buttons held, frame by frame: down and up on the title's menu, A on START, then the
  # paddle up and down once the rally is under way.
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([20..20, :down], [24..24, :up], [30..30, :a], [60..80, :up], [81..110, :down])
  )

  def test_pong_gbc_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(PongGBC::GAME, err: nil)

    last = assert_recorded_run_matches_reference program, frames: 110, buttons: RUN

    assert_equal 1, last.variables[:state], "the run should end in the rally"
  end
end
