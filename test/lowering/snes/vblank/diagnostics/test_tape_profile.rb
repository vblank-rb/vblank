# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# A tape played on a Super Nintendo cartridge, each frame asked for read by itself
# (Diagnostics::TapeProfile, `rom.profile(tape:, frames:)`).
class TestTapeProfile < Minitest::Test
  # A pass that is light, unless B is down: then a routine of its own does more work, still inside a
  # frame. Holding A does far more than a frame holds.
  WALKER = VBlank.game("WALKER", consoles: %i[snes]) do
    total = 0
    func(:walk) { repeat(150) { total += 3 } }
    func(:march) { repeat(9000) { total += 3 } }
    func(:stand) { repeat(20) { total += 3 } }
    game_loop do
      call :stand
      call :walk if held(:b)
      call :march if held(:a)
    end
  end

  # Nothing for 100 frames, B for 20, nothing for 20, A for 4, then nothing.
  PRESSES = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: WALKER 0x00000000
    starts from: power-on

    100 -
    20 b
    20 -
    4 a
    40 -
  TAPE

  EMPTY = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: WALKER 0x00000000
    starts from: power-on
  TAPE

  def test_a_frame_made_slow_by_a_press_has_fewer_lines_spare_and_names_the_routine
    result = rom.profile(out: StringIO.new, tape: PRESSES, frames: 90..115)

    still = result.frame(90)
    walking = result.frame(110)

    assert_equal [], still.buttons
    assert_equal [:b], walking.buttons
    assert_operator walking.lines_spare, :<, still.lines_spare
    assert_match(/walk/, walking.game.first.routine.to_s)
    assert(result.readings.all?(&:new_picture?), "B's work fits in a frame")
  end

  def test_a_pass_too_long_for_a_frame_holds_the_picture_and_says_the_pass_did
    result = rom.profile(out: StringIO.new, tape: PRESSES, frames: 135..160)

    held = result.held

    refute_empty held
    assert_equal [:pass], held.map(&:picture_held_by).uniq
    assert(held.all? { |reading| reading.frame > 140 }, "only A's frames are slow")
  end

  # A painted screen that is cleared and left alone, unless A is down: then forty squares go up in
  # one of two places by turns, so every pass changes many tiles of the picture. Painting them is
  # work in the pass; sending them to the console is work after it, and more than one blank holds.
  REPAINTER = VBlank.game("REPAINTER", consoles: %i[snes]) do
    screen :bitmap
    n = 0
    game_loop do
      n += 1
      clear_screen :black
      if held(:a) && n % 2 != 0
        40.times { |t| fill_rect (t % 8) * 24, (t / 8) * 24, 6, 6, :green }
      end
      if held(:a) && n % 2 == 0
        40.times { |t| fill_rect ((t % 8) * 24) + 12, ((t / 8) * 24) + 12, 6, 6, :red }
      end
    end
  end

  # Nothing for 100 frames, then A for 6.
  REPAINTS = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: REPAINTER 0x00000000
    starts from: power-on

    100 -
    6 a
    40 -
  TAPE

  def test_a_picture_held_by_the_work_after_the_pass_is_told_from_one_held_by_the_pass
    rom = REPAINTER.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, tape: REPAINTS, frames: 90..120)

    assert(result.readings.select { |reading| reading.frame <= 100 }.all?(&:new_picture?), "standing still keeps up")
    assert_includes result.held.map(&:picture_held_by), :pass
    assert_includes result.held.map(&:picture_held_by), :gap
    assert(result.held.select { |reading| reading.picture_held_by == :gap }.all? { |reading| reading.game.empty? },
           "none of the game's own routines run in the gap")
  end

  # The answer key: the profile of the game standing still, read over the same frames.
  def test_an_empty_tape_agrees_with_the_profile_standing_still
    still = rom.profile(out: StringIO.new, frames: 20)
    taped = rom.profile(out: StringIO.new, tape: EMPTY, frames: still.measured_frames)

    assert_equal still.measured_frames.to_a, taped.readings.map(&:frame)
    assert_equal still.fewest_lines_spare, taped.readings.map(&:lines_spare).min
    assert_equal still.game.first.routine, taped.readings.first.game.first.routine
  end

  def test_the_report_says_each_frame_in_plain_words
    out = StringIO.new
    rom.profile(out: out, tape: PRESSES, frames: 109..110)

    assert_match(/Frame 110 \(holding B\): \d+ lines to spare/, out.string)
    assert_match(/new picture/, out.string)
  end

  def test_the_report_comes_as_data_too
    out = StringIO.new
    rom.profile(out: out, format: :json, tape: PRESSES, frames: 109..110)

    assert_equal [109, 110], JSON.parse(out.string).fetch("frames").map { |frame| frame.fetch("frame") }
  end

  def test_frames_that_are_not_a_range_are_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, tape: PRESSES, frames: 20) }

    assert_match(/range of frames/, error.message)
  end

  def test_settling_beside_a_tape_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, tape: PRESSES, frames: 1..2, settle: 10) }

    assert_match(/settle:/, error.message)
  end

  def test_a_tape_of_passes_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, tape: PRESSES.with(in_passes: true), frames: 1..2) }

    assert_match(/in_frames_on/, error.message)
  end

  private def rom = WALKER.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
end
