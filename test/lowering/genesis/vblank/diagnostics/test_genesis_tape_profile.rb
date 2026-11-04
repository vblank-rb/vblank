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

  private def rom = WALKER.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
end
