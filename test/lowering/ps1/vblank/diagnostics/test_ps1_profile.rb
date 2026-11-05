# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# A PlayStation program measured as it runs (Diagnostics::PS1Profiler, `rom.profile`): how many frames
# each pass took, which routines took the processor's time, and how long the graphics chip drew.
class TestPS1Profile < Minitest::Test
  # A routine of the game's that does most of the work there is, inside a frame.
  BUSY = VBlank.game("BUSY", consoles: %i[ps1]) do
    total = 0
    func(:hard_work) { repeat(2000) { total += 3 } }
    game_loop { call :hard_work }
  end

  # A routine too long for one frame: each pass takes two.
  SLOW = VBlank.game("SLOW", consoles: %i[ps1]) do
    total = 0
    func(:too_much) { repeat(30_000) { total += 3 } }
    game_loop { call :too_much }
  end

  # Work that runs a few lines past the blank after it began: each pass then waits for the next blank,
  # and takes two frames. The count was found by playing it.
  JUST_LATE_STEPS = 29_500
  JUST_LATE = VBlank.game("JUST LATE", consoles: %i[ps1]) do
    total = 0
    func(:a_little_too_much) { repeat(JUST_LATE_STEPS) { total += 3 } }
    game_loop { call :a_little_too_much }
  end

  # The same work and a little more, so each pass ends further past the blank.
  LATER = VBlank.game("LATER", consoles: %i[ps1]) do
    total = 0
    func(:a_little_too_much) { repeat(JUST_LATE_STEPS + 600) { total += 3 } }
    game_loop { call :a_little_too_much }
  end

  # Work for a little over two frames: each pass runs past its second blank into a third frame, well
  # past the blank's own lines. Its count was found by playing it too.
  PAST_TWO_FRAMES = VBlank.game("PAST TWO", consoles: %i[ps1]) do
    total = 0
    func(:too_much) { repeat(62_000) { total += 3 } }
    game_loop { call :too_much }
  end

  # A routine of its own that does more while B is down.
  WALKER = VBlank.game("WALKER", consoles: %i[ps1]) do
    total = 0
    func(:walk) { repeat(400) { total += 3 } }
    func(:stand) { repeat(20) { total += 3 } }
    game_loop do
      call :stand
      call :walk if held(:b)
    end
  end

  # Rectangles over the whole screen, painted every pass: the graphics chip's work.
  PAINTER = VBlank.game("PAINTER", consoles: %i[ps1]) do
    screen :bitmap
    game_loop do
      repeat(6) { fill_rect 0, 0, screen_width, screen_height, :blue }
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

  def test_the_report_names_the_routine_the_frame_went_on_and_what_was_left
    out = StringIO.new
    result = rom(BUSY).profile(out: out, frames: 20)

    assert_equal 20, result.passes
    assert_equal({ 1 => 20 }, result.passes_by_frames)
    assert_operator result.idle_share, :>, 0.1
    assert_operator result.idle_share, :<, 1
    assert_operator result.fewest_lines_spare, :>, 10
    assert_operator result.fewest_lines_spare, :<, 263
    assert_match(/hard_work/, result.game.first.routine)
    assert_operator result.game.first.share, :>, 0.05
    assert_match(/PlayStation: 20 passes/, out.string)
    assert_match(/lines to spare/, out.string)
  end

  # The frames each pass took are the runtime's own count (Runtime::Frame::STEPS), and the time read
  # from the emulator says the same: a pass of two frames leaves next to nothing to spare.
  def test_a_pass_too_long_for_a_frame_is_counted_as_the_frames_it_took
    result = rom(SLOW).profile(out: StringIO.new, frames: 10)

    assert_equal({ 2 => 10 }, result.passes_by_frames)
    assert_in_delta 30.0, result.fps, 0.2
    assert_match(/too_much/, result.game.first.routine)
    assert_operator result.idle_share, :<, 0.5
  end

  # The lines are read from the run: where the pass went to sleep, counted by the console's own line
  # timer from the blank that began while it ran.
  def test_a_pass_that_ends_a_few_lines_past_the_blank_is_reported_late_by_those_lines
    out = StringIO.new
    result = rom(JUST_LATE).profile(out: out, frames: 10)

    assert_equal({ 2 => 10 }, result.passes_by_frames)
    assert_equal 10, result.late_passes.size
    assert(result.late_passes.all? { |lines| lines.between?(1, 20) }, "late by #{result.late_passes}")
    assert_equal({ 2 => result.late_passes }, result.lines_past_blank)
    assert_match(/10 passes ended after the break between pictures began.*Ending \d+( to \d+)? lines? sooner/, out.string)
    assert_match(/10 passes of 2 frames ran \d+( to \d+)? lines? past the last break between pictures/, out.string)
  end

  def test_more_work_past_the_blank_is_more_lines_late
    late = rom(JUST_LATE).profile(out: StringIO.new, frames: 6)
    later = rom(LATER).profile(out: StringIO.new, frames: 6)

    assert_equal [{ 2 => 6 }] * 2, [late.passes_by_frames, later.passes_by_frames]
    assert_operator later.late_passes.min, :>, late.late_passes.max
  end

  # A pass that runs well into a third frame is not a few lines late, so the Advance's line leaves it
  # out; how far past its second blank it ran is said by the frames it took.
  def test_a_pass_of_three_frames_says_how_far_past_its_second_blank_it_ran
    out = StringIO.new
    result = rom(PAST_TWO_FRAMES).profile(out: out, frames: 6)

    assert_equal({ 3 => 6 }, result.passes_by_frames)
    assert_empty result.late_passes
    assert(result.lines_past_blank.fetch(3).all? { |lines| lines.between?(24, 120) }, result.lines_past_blank.inspect)
    assert_match(/6 passes of 3 frames ran \d+( to \d+)? lines past the last break between pictures/, out.string)
  end

  def test_a_game_that_keeps_up_has_no_late_passes
    out = StringIO.new
    result = rom(BUSY).profile(out: out, frames: 10)

    assert_empty result.late_passes
    assert_empty result.lines_past_blank
    refute_match(/break between pictures/, out.string)
  end

  def test_the_graphics_chip_drawing_is_its_share_of_the_time
    painted = rom(PAINTER).profile(out: StringIO.new, frames: 10)
    idle = rom(BUSY).profile(out: StringIO.new, frames: 10)

    assert_operator painted.gpu_share, :>, 0.2
    assert_operator painted.gpu_share, :<=, 1
    assert_operator idle.gpu_share, :<, 0.01
  end

  # The reader counts passes the way the profile does, from the runtime's own count, so a slow pass is
  # one pass however many frames it took.
  def test_the_reader_counts_the_passes_the_program_finished
    shorter = VBlank::Diagnostics::Verifier.new(rom(SLOW), frames: 8).passes
    longer = VBlank::Diagnostics::Verifier.new(rom(SLOW), frames: 18).passes

    assert_equal 5, longer - shorter
  end

  def test_json_carries_the_same
    out = StringIO.new
    rom(BUSY).profile(out: out, frames: 10, format: :json)
    data = JSON.parse(out.string)

    assert_equal 10, data.fetch("passes")
    assert_match(/hard_work/, data.fetch("game").first.fetch("routine"))
    assert data.key?("gpu_share")
    assert_equal [], data.fetch("late_passes")
  end

  def test_a_frame_made_slow_by_a_press_names_its_routine
    result = rom(WALKER).profile(out: StringIO.new, tape: PRESSES, frames: 90..115)

    assert_operator result.frame(110).lines_spare, :<, result.frame(90).lines_spare
    assert_match(/walk/, result.frame(110).game.first.routine.to_s)
    assert(result.readings.all?(&:new_picture?), "B's work fits in a frame")
  end

  def test_an_empty_tape_agrees_with_the_profile_standing_still
    still = rom(WALKER).profile(out: StringIO.new, frames: 20)
    taped = rom(WALKER).profile(out: StringIO.new, tape: EMPTY, frames: still.measured_frames)

    assert_equal still.fewest_lines_spare, taped.readings.map(&:lines_spare).min
    assert_equal still.game.first.routine, taped.readings.first.game.first.routine
  end

  private def rom(game) = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
end
