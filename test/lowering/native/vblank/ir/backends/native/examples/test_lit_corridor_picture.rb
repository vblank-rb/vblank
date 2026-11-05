# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/lit_corridor").to_s

# examples/lit_corridor.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while the viewer flies down the corridor and turns, and the lamp flickers: the
# light of every corner, and the random rolls that dim the lamp, agree on every frame.
class TestLitCorridorPicture < Minitest::Test
  include NativeComparison

  # Ahead, then a turn to the left and back to the right.
  FLIGHT = Ractor.make_shareable(NativeComparison.held_for([2..14, :a], [15..20, :left], [21..26, :right]))

  def test_lit_corridor_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(LitCorridor::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 30, buttons: FLIGHT
  end
end
