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

  def test_the_corridor_at_the_start_agrees
    assert_backends_agree(LitCorridor.program, frames: 3, console_frames: 20, name: "LITHALL")
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
