# frozen_string_literal: true

require "test_helper"
require "stringio"

# A tape played on a Genesis cartridge, each frame asked for read by itself
# (Diagnostics::TapeProfile, `rom.profile(tape:, frames:)`).
class TestGenesisTapeProfile < Minitest::Test
  # A light pass, unless B is down: then a routine of its own does more work, still inside a frame.
  WALKER = VBlank.game("WALKER", consoles: %i[genesis]) do
    total = 0
    func(:walk) { repeat(60) { total += 3 } }
    func(:stand) { repeat(5) { total += 3 } }
    game_loop do
      call :stand
      call :walk if held(:b)
    end
  end

  PRESSES = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: WALKER 0x00000000
    starts from: power-on

    100 -
    20 b
    20 -
  TAPE

  EMPTY = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: WALKER 0x00000000
    starts from: power-on
  TAPE

  def test_a_frame_made_slow_by_a_press_has_fewer_lines_spare_and_names_the_routine
    result = rom.profile(out: StringIO.new, tape: PRESSES, frames: 90..115)

    assert_operator result.frame(110).lines_spare, :<, result.frame(90).lines_spare
    assert_match(/walk/, result.frame(110).game.first.routine.to_s)
    assert(result.readings.all?(&:new_picture?), "B's work fits in a frame")
  end

  def test_an_empty_tape_agrees_with_the_profile_standing_still
    still = rom.profile(out: StringIO.new, frames: 20)
    taped = rom.profile(out: StringIO.new, tape: EMPTY, frames: still.measured_frames)

    assert_equal still.fewest_lines_spare, taped.readings.map(&:lines_spare).min
    assert_equal still.game.first.routine, taped.readings.first.game.first.routine
  end

  def test_a_frame_keeps_as_many_routines_as_the_profile_is_told
    one = rom.profile(out: StringIO.new, tape: PRESSES, frames: 110..110, routines: 1).frame(110)
    many = rom.profile(out: StringIO.new, tape: PRESSES, frames: 110..110, routines: 8).frame(110)

    assert_equal 1, one.game.length
    assert_equal 1, one.runtime.length
    assert_operator many.game.length, :>, VBlank::Diagnostics::TapeProfile::ROUTINES_KEPT
    assert_equal one.game.first, many.game.first
  end

  def test_a_number_of_routines_that_is_not_one_or_more_is_refused
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, tape: PRESSES, frames: 110..110, routines: 0) }

    assert_includes error.message, "routines:"
  end

  def test_routines_without_a_tape_is_refused
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, frames: 20, routines: 5) }

    assert_includes error.message, "tape"
  end

  # Every fourth pass does far more work than a frame holds.
  HEAVY_NOW_AND_THEN = VBlank.game("HEAVY", consoles: %i[genesis]) do
    total = 0
    pass = 0
    game_loop do
      pass += 1
      repeat(9000) { total += 3 } if (pass & 3) == 0
    end
  end

  # The frames the profile names for its slowest pass are that pass's own: read one by one, one
  # pass ends in them, on the last, and every one after the first shows no new picture, since the
  # pass is still running. The first shows the picture of the pass before.
  def test_the_frames_named_for_the_slowest_pass_are_the_ones_a_tape_reads_it_on
    heavy = HEAVY_NOW_AND_THEN.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    out = StringIO.new
    still = heavy.profile(out: out, frames: 20)
    frames = still.slowest_pass_frames
    readings = heavy.profile(out: StringIO.new, tape: EMPTY, frames: frames).readings

    assert_equal still.slowest_frames, frames.size
    assert_includes out.string, "frames #{frames.begin} to #{frames.end} from power-on"
    assert_equal [0] * (frames.size - 1) + [1], readings.map(&:passes_ended)
    assert_equal [:pass], readings.drop(1).map(&:picture_held_by).uniq
    assert_predicate readings.first, :new_picture?
  end

  private def rom = WALKER.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
end
