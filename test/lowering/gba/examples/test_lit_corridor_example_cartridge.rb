# frozen_string_literal: true

require "test_helper"
require "differential"
require VBlank.root.join("examples/lit_corridor").to_s

# The Lit Corridor example (examples/lit_corridor.rb) on the Advance's own cartridge, read back in
# the emulator: every lit pixel the colour the interpreter gives it, standing still as the lamp
# flickers and flying down the corridor. What the example does on every run that plays the Advance
# is in test/console/gba/examples/test_lit_corridor_example.rb.
class TestLitCorridorExampleCartridge < Minitest::Test
  include Differential

  # THE LAMP FLICKERS WITH NOBODY AT THE CONTROLS, so the picture changes from one pass to the next
  # even standing still, and a pass takes the cartridge several frames. On the frame a pass ends the
  # count of passes has gone up and the page that pass drew is not shown until the next frame, so
  # that one frame shows the pass before the one counted. Which frame that is moves whenever the
  # fill gets faster or slower, so the frame is read as assert_backends_agree_by_passes says: with
  # the passes counted a frame earlier.
  def test_the_corridor_at_the_start_agrees
    assert_backends_agree_by_passes(LitCorridor.program, frame: 20, name: "LITHALL")
  end

  # Each pass compared is its own run, with the buttons held from power-on: the lamp dimmed and
  # bright again, then the viewer flying towards it and turning.
  def test_the_flicker_and_a_flight_agree_pass_by_pass
    [[[], [12, 30]], [%i[a], [40, 90]], [%i[left], [30]]].each do |keys, console_frames|
      console_frames.each do |frame|
        assert_backends_agree_by_passes(LitCorridor.program, frame: frame, keys: keys, name: "LITHALLFLY")
      end
    end
  end
end
