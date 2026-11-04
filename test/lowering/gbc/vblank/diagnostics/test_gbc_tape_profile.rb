# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

# A tape played on a Game Boy Color cartridge, each frame asked for read by itself
# (Diagnostics::TapeProfile with Diagnostics::GBCProfiler as its meter, `rom.profile(tape:, frames:)`).
class TestGBCTapeProfile < Minitest::Test
  # A title that wants A pressed twice, as a menu reads a press: the frame it goes down. Five passes
  # after the second press, one pass spins a long count, and every other pass is light. Holding A
  # from power-on is one press however long it is held, so only presses on given frames reach the
  # spin.
  ROULETTE = VBlank.game("ROULETTE", consoles: %i[gba gbc]) do
    total = 0
    presses = 0
    passes_in = 0
    func(:spin) { repeat(200) { total += 3 } }
    func(:idle) { repeat(10) { total += 1 } }
    game_loop do
      call :idle
      presses += 1 if pressed(:a)
      if presses >= 2
        passes_in += 1
        call :spin if passes_in == 5
      end
    end
  end

  # A down on frames 30 and 40, and nothing else.
  PRESSES = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: ROULETTE 0x00000000
    starts from: power-on

    29 -
    1 a
    9 -
    1 a
    40 -
  TAPE

  EMPTY = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: ROULETTE 0x00000000
    starts from: power-on
  TAPE

  def test_the_one_heavy_frame_reached_by_presses_stands_out
    result = rom.profile(out: StringIO.new, tape: PRESSES, frames: 35..60)

    spun = result.readings.select { |reading| reading.game.any? { |row| row.routine == "spin" } }
    light = result.readings - spun
    assert_equal [result.busiest], spun, "spin runs on one frame, and it is the busiest"
    assert_operator spun.first.frame, :>, 40
    assert_operator spun.first.awake_share, :>, 3 * light.map(&:awake_share).max
    assert_operator spun.first.lines_spare, :<, light.map(&:lines_spare).min
  end

  def test_holding_the_button_from_power_on_never_reaches_it
    held = rom.profile(out: StringIO.new, keys: [:a], settle: 0, frames: 120)

    refute_includes held.game.map(&:routine), "spin"
  end

  # The answer key: the profile of the game standing still, read over the same frames.
  def test_an_empty_tape_agrees_with_the_profile_standing_still
    still = rom.profile(out: StringIO.new, frames: 20)
    taped = rom.profile(out: StringIO.new, tape: EMPTY, frames: still.measured_frames)

    awake = taped.readings.sum(&:awake_share) / taped.readings.size
    assert_equal still.measured_frames.to_a, taped.readings.map(&:frame)
    assert_in_delta 1 - still.idle_share, awake, 0.01
    assert_equal still.game.first.routine, taped.readings.first.game.first.routine
    assert(taped.readings.all?(&:new_picture?), "a light game shows a new picture every frame")
  end

  def test_the_report_says_each_frame_in_plain_words
    out = StringIO.new
    rom.profile(out: out, tape: PRESSES, frames: 40..50)

    assert_match(/Frame 40 \(holding A\): \d+ lines to spare, awake \d+\.\d%/, out.string)
    assert_match(/The busiest frame was 4\d: the game was awake for/, out.string)
    assert_match(/yours: .*spin/, out.string)
  end

  def test_the_report_comes_as_data_too
    out = StringIO.new
    rom.profile(out: out, format: :json, tape: PRESSES, frames: 39..40)

    frames = JSON.parse(out.string).fetch("frames")
    assert_equal [39, 40], frames.map { |frame| frame.fetch("frame") }
    assert(frames.all? { |frame| frame.fetch("awake_share").between?(0, 1) })
  end

  def test_settling_beside_a_tape_is_refused_in_plain_words
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, tape: PRESSES, frames: 1..2, settle: 10) }

    assert_match(/settle:/, error.message)
  end

  def test_a_scene_says_to_reach_the_moment_with_a_tape
    error = assert_raises(ArgumentError) { rom.profile(out: StringIO.new, scene: :title) }

    assert_match(/--tape/, error.message)
  end

  private def rom = ROULETTE.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false)
end
