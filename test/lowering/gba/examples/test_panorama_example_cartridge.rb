# frozen_string_literal: true

require "test_helper"
require "differential"
ShareableConstants.require_file(VBlank.root.join("examples/panorama").to_s)

# The Panorama example's cartridge (examples/panorama.rb), read back in the emulator: the Advance
# keeps its own screen, so the picture pans across it as the interpreter pans it. What each build
# shows is in test/all/examples/test_panorama_example.rb.
class TestPanoramaExampleCartridge < Minitest::Test
  include Differential

  # The cartridge's passes are counted and the interpreter plays as many, since drawing the whole
  # screen each pass now and then takes the cartridge more than one frame.
  def test_the_picture_pans_as_on_the_interpreter
    [3, 60].each do |frames|
      assert_backends_agree(Panorama.program, frames: frames, name: "PANORAMA")
    end
  end
end
