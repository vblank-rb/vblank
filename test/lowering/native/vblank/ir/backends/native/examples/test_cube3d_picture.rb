# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/cube3d").to_s

# examples/cube3d.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the viewer turns round the crate, rolls, flies in, and holds START so the top
# shows the side boards' picture.
class TestCube3DPicture < Minitest::Test
  include NativeComparison

  # Left and up, a roll, nearer, and START held at the end.
  FLIGHT = Ractor.make_shareable(
    NativeComparison.held_for([2..8, :left], [9..14, :up], [15..18, :r], [19..26, :a], [27..30, :start])
  )

  def test_cube3d_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Cube3D::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 30, buttons: FLIGHT
  end
end
