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

  # Each pass compared is its own run, with the buttons held from power-on: the viewer nearing the
  # doorway, standing in it, through it, and turning. The comparison counts the cartridge's passes
  # and plays the interpreter as many.
  #
  # THE CARTRIDGE TAKES ONE FRAME A PASS OR SEVERAL here, more where more of the screen is filled,
  # and the frame a pass ends on is read between two pictures. Two passes in a row end on two
  # frames in a row at most (measured frame by frame through the doorway), so of three frames in a
  # row one falls inside a pass: each is read until one agrees, the interpreter playing as many
  # passes as the cartridge counted by then.
  def test_a_flight_through_the_doorway_agrees_pass_by_pass
    [[%i[a], [40, 120, 135, 150, 162]], [%i[left], [21, 72]]].each do |keys, console_frames|
      console_frames.each do |frame|
        differing = (frame..(frame + 2)).map do |read|
          oracle, console, = backend_pictures(TwoRooms.program, frames: read, console_frames: read, keys: keys,
                                                                name: "TWOROOMSFLY")
          mismatched_pixels(oracle, console).length
        end
        assert_includes differing, 0, "none of frames #{frame} to #{frame + 2} agreed, holding #{keys.inspect}"
      end
    end
  end
end
