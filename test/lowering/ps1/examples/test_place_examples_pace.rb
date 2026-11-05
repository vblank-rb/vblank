# frozen_string_literal: true

require "test_helper"
require "stringio"

require VBlank.root.join("examples/two_rooms").to_s
require VBlank.root.join("examples/cube3d").to_s

# How fast the examples that draw a place run on the PlayStation, measured in Beetle PSX
# (Diagnostics::PS1Profiler): the frames each pass of the game loop takes, by the runtime's own count.
# A PlayStation game of the time drew a view like these at a pass a frame, so these do too.
class TestPlaceExamplesPaceOnThePlayStation < Minitest::Test
  # Standing at the start, looking through the doorway: the stone room over the whole screen and the
  # brick room through the doorway, two drawings of a place each pass.
  def test_two_rooms_standing_still_runs_a_pass_a_frame
    result = profile(TwoRooms)

    assert_equal({ 1 => 30 }, result.passes_by_frames)
  end

  def test_cube3d_at_the_start_runs_a_pass_a_frame
    result = profile(Cube3D)

    assert_equal({ 1 => 30 }, result.passes_by_frames)
  end

  private def profile(example)
    rom = example::GAME.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 30)
  end
end
