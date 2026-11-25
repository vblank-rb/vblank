# frozen_string_literal: true

require "test_helper"
require "differential"

require "stringio"
ShareableConstants.require_file(VBlank.root.join("examples/meadow").to_s)
require "all/examples/test_meadow_example"

# The Meadow example on the Advance's cartridge (examples/meadow.rb), read in the emulator: it builds, and the
# cartridge draws what the interpreter draws on the way out of the door. What the walk does on every console the
# game is written for is in test/all/examples/test_meadow_example.rb, whose walk (MeadowWalk) these share.
class TestMeadowExampleOnTheAdvance < Minitest::Test
  include Differential
  include MeadowWalk

  def test_it_builds_a_rom
    assert_operator Meadow.build_rom(err: StringIO.new).size, :>, 0
  end

  def test_both_backends_draw_the_cabin
    assert_backends_agree(Meadow.program, frames: 3, name: "MEADA")
  end

  # Out of the door: into the blocks, each frame about the swap, the way back, and down the path.
  def test_both_backends_draw_the_walk_into_the_meadow
    _pictures, broke_up, swapped = walk_through_door
    frames = [broke_up + 3, *((swapped - 1)..(swapped + 3)), swapped + 8, 70]

    frames.each { |count| assert_backends_agree(Meadow.program, frames: count, name: "MEADB", keys: [:down]) }
  end
end
