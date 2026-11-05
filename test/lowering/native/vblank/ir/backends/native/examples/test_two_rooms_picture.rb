# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/two_rooms").to_s

# examples/two_rooms.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while the viewer turns and flies: the far room is drawn through the doorway's
# window, and the window moves on the screen as the viewer does.
class TestTwoRoomsPicture < Minitest::Test
  include NativeComparison

  # A turn to the left and back, then ahead.
  FLIGHT = Ractor.make_shareable(NativeComparison.held_for([2..7, :left], [8..13, :right], [14..30, :a]))

  def test_two_rooms_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(TwoRooms::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 30, buttons: FLIGHT
  end
end
