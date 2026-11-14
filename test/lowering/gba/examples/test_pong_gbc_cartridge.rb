# frozen_string_literal: true

require "test_helper"
require "stringio"
require VBlank.root.join("examples/pong_gbc").to_s

# examples/pong_gbc.rb built for the Advance, in the border round the Color's screen.
class TestPongGBCCartridge < Minitest::Test
  # The build measures the frame the game changes scene on, and warns of each that runs past its
  # end. The border's pictures go up once at power-on (GBA::BorderSprites#emit_at_power_on): sent
  # again on every change into a painted scene, they ran three of Pong's changes past their frames,
  # which the Color build of the same game, and the Advance's without the border, do not.
  def test_its_scene_changes_fit_their_frames
    err = StringIO.new
    PongGBC::GAME.build_rom(console: :gba, out: StringIO.new, err: err)

    refute_match(/runs past its end/, err.string)
  end
end
