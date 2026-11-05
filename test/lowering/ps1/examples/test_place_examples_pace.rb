# frozen_string_literal: true

require "test_helper"
require "stringio"

require VBlank.root.join("examples/two_rooms").to_s
require VBlank.root.join("examples/cube3d").to_s
require VBlank.root.join("examples/lit_corridor").to_s

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

  # Standing at the start of the corridor, the lamp's ring of walls lit and the rest dimmer: lit, a pass
  # fits in two frames, as the corridor drawn unlit does, and lighting costs no more than a third again
  # of the processor's time drawn unlit, as on the Advance (.claude/dsl/places.md).
  def test_the_lit_corridor_runs_as_fast_as_unlit_and_lighting_costs_under_a_third_again
    lit = profile(LitCorridor)
    unlit = profile(LitCorridor, lit: false)

    assert_equal({ 2 => 30 }, lit.passes_by_frames)
    assert_equal unlit.passes_by_frames, lit.passes_by_frames
    assert_operator busy_frames(lit), :<, busy_frames(unlit) * 4 / 3.0
  end

  # How much of a frame the processor was at work for, a pass.
  private def busy_frames(result) = (1 - result.idle_share) * result.frames / result.passes

  private def profile(example, **settings)
    rom = example::GAME.build_rom(console: :ps1, settings: settings, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 30)
  end
end
