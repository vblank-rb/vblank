# frozen_string_literal: true

require "test_helper"
require "differential"
require "console/gba/examples/test_two_rooms_example"

# The Two Rooms example (examples/two_rooms.rb) on the Advance's own cartridge, read back in the
# emulator: each room where the interpreter draws it, held to the window the game works out, from a
# viewer standing still, flying through the doorway and turning. What the example does on every
# run that plays the Advance is in test/console/gba/examples/test_two_rooms_example.rb.
class TestTwoRoomsExampleCartridge < Minitest::Test
  include Differential

  def test_the_doorway_at_the_start_agrees
    assert_backends_agree(TwoRooms.program, frames: 3, console_frames: 20, name: "TWOROOMS")
  end

  # Each pass compared is its own run, with the buttons held from power-on (see
  # test/lowering/gba/examples/test_cube3d_example_cartridge.rb for why the frame is given): the
  # viewer nearing the doorway, standing in it, through it, and turning.
  def test_a_flight_through_the_doorway_agrees_pass_by_pass
    [[%i[a], [10, 36, 41, 50]], [%i[left], [20, 45]], [%i[right a], [30]]].each do |keys, passes|
      passes.each do |pass|
        assert_backends_agree(TwoRooms.program, frames: pass, console_frames: (2 * pass) + 4, keys: keys,
                                                name: "TWOROOMSFLY")
      end
    end
  end
end
