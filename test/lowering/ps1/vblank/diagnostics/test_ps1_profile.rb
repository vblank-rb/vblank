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
