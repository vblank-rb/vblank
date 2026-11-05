# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/everywhere").to_s

# examples/everywhere.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while its ball bounces off the right wall with a click and the tune plays. Nobody
# holds a button: the ball moves by itself.
class TestEverywherePicture < Minitest::Test
  include NativeComparison

  # The ball starts in the middle and moves two pixels right a pass, so it has met the right wall
  # and turned round well before this.
  FRAMES = 70

  def test_everywhere_matches_the_interpreter_while_the_ball_bounces
    program = Native.new.checked_program(Everywhere::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: FRAMES)

    assert_operator last.variables[:dx], :<, 0, "the ball should have turned round at the right wall"
  end
end
