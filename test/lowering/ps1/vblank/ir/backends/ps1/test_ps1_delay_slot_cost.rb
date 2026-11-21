# frozen_string_literal: true

require "test_helper"
require "stringio"

# What a loop of the game's costs on the PlayStation, read from where Beetle PSX says the time went. The
# R3000 runs the instruction after every branch whether the branch is taken or not, and a loop is mostly
# branches: with a NOP after each one, a turn of the plainest loop there is spent one of its
# instructions doing nothing. The assembler now moves the instruction before a branch into that slot
# where it can (R3000#take_slot_filler), and this holds what the loop costs with them filled.
class TestPS1DelaySlotCost < Minitest::Test
  TURNS = 2000
  CYCLES_A_FRAME = VBlank::Console::PLAYSTATION.cycles_a_frame

  # Each pass adds to a number TURNS times, in a routine of its own so the profile names it.
  COUNTING = VBlank.game("COUNTING", consoles: %i[ps1]) do
    total = 0
    func(:count_up) { repeat(TURNS) { total += 3 } }
    game_loop { call :count_up }
  end

  # Each turn tests a number as well, so a turn has a branch of the game's own beside the loop's.
  TESTING = VBlank.game("TESTING", consoles: %i[ps1]) do
    total = 0
    odd = 0
    func(:count_odd) do
      repeat(TURNS) do
        total += 3
        odd += 1 if total > 1000
      end
    end
    game_loop { call :count_odd }
  end

  # The processor's cycles one turn of +game+'s busiest routine took.
  private def cycles_a_turn(game)
    rom = game.build_rom(console: :ps1, out: StringIO.new, err: StringIO.new, profile: false)
    result = rom.profile(out: StringIO.new, frames: 4)

    assert_equal 1, result.slowest_frames, "every pass fits a frame, so a frame's time is one pass's turns"
    result.game.first.share * CYCLES_A_FRAME / TURNS
  end

  # A NOP in the loop's own slot made a turn sixteen cycles.
  def test_a_turn_of_a_counting_loop_costs_fifteen_cycles
    assert_operator cycles_a_turn(COUNTING), :<, 15.5
  end

  # ...and twenty-three with a test in it. The test's own slot stays a NOP: the instruction before
  # its branch makes what the branch tests.
  def test_a_turn_that_tests_a_number_costs_twenty_two_cycles
    assert_operator cycles_a_turn(TESTING), :<, 22.5
  end
end
