# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/bird").to_s

# examples/bird.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, through a flight: right, then a climb with the nose tipped up, a dive with it tipped
# down, and level again, while the bird drifts nearer and further the whole time.
class TestBirdPicture < Minitest::Test
  include NativeComparison

  FLIGHT = Ractor.make_shareable(
    NativeComparison.held_for([2..25, :right], [26..50, :up], [51..90, :down], [91..110, :left])
  )
  # One drift from furthest to nearest and back is two and a half seconds, 150 frames: this is
  # all the way to its nearest and most of the way back.
  FRAMES = 120

  def test_bird_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Bird::GAME, err: nil)
    moments = reference_snapshots(program, frames: FRAMES, buttons: FLIGHT)
    birds = moments.map { |moment| moment.read_with(program).sprite(:bird) }

    assert_recorded_run_matches_reference(program, frames: FRAMES, buttons: FLIGHT)

    assert_equal [0, 335, 25, 0], birds.map(&:angle).chunk_while { |a, b| a == b }.map(&:first),
                 "level, nose up for the climb, nose down for the dive, level again"
    assert_operator birds.map(&:scale).min, :<, 0.8, "it should have been drawn well under its own size"
    assert_operator birds.map(&:scale).max, :>, 1.2, "and well over it"
  end
end
