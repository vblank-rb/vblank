# frozen_string_literal: true

require "test_helper"
require "differential"
require "console/gba/examples/test_cube3d_example"

# The Cube 3D example (examples/cube3d.rb) on the Advance's own cartridge, read back in the
# emulator: the crate where the interpreter draws it, from a viewer standing still, flying and
# turning. What the example does on every run that plays the Advance is in
# test/console/gba/examples/test_cube3d_example.rb.
class TestCube3DExampleCartridge < Minitest::Test
  include Differential

  def test_the_crate_at_the_start_agrees
    assert_backends_agree(Cube3D.program, frames: 3, console_frames: 20, name: "CUBE3D")
  end

  # Each frame compared is its own run, with the buttons held from power-on: a viewer flying in,
  # turning, tipping and rolling, the crate drawn from a new place on every pass. How many frames a
  # pass takes changes with how much of the screen the crate covers, so each is read as
  # assert_backends_agree_by_passes says.
  def test_a_moving_viewer_agrees_pass_by_pass
    [%i[a], %i[right], %i[up a], %i[l]].each do |keys|
      [6, 12, 20].each do |frame|
        assert_backends_agree_by_passes(Cube3D.program, frame: frame, keys: keys, name: "CUBE3DFLY")
      end
    end
  end
end
