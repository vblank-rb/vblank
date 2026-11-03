# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/flowers").to_s

# examples/flowers.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, through every picture of the flowers' sway and back to the first: the map never
# changes, and each flower in the field leans because its one tile is shown from another picture.
class TestFlowersPicture < Minitest::Test
  include NativeComparison

  def test_flowers_matches_the_interpreter_through_a_whole_sway
    program = Native.new.checked_program(Flowers::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: Flowers::FRAMES_A_PICTURE * 5)

    assert_includes last.picture, Color.resolve(:yellow), "flowers should be in the last picture compared"
  end
end
