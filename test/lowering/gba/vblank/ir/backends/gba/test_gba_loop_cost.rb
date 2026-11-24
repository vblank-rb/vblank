# frozen_string_literal: true

require "test_helper"
require "loop_cost_games"

# A turn of a loop on the Advance, measured in the emulator: a `repeat`, and a game's `while i < n`
# with `i += 1` last, which the build lowers as a counted loop (Backends::LoopForm#counted_while,
# Statements#emit_counted_while). The ARM's own way is a count in a register, ADD and CMP and a B
# back, or a SUBS that is its own test (GBATEK, "ARM CPU Instruction Cycle Times"). A loop here keeps
# its count and limit in r10 and r11 where nothing in the body needs them (GBA::LoopForm), and a
# counted while keeps the game's variable there. The bodies set a variable, `c = 1`, or read a list
# at the count.
class TestGBALoopCost < Minitest::Test
  # A frame's cycles: 228 lines of 1232.
  FRAME_CYCLES = 280_896

  # Measured: a repeat 6 a turn setting (it counts down, its index unread), 26 reading. A counted
  # while was 16 and 38 while it was written as it reads (its hidden count kept in memory, `i` loaded
  # to be compared and added to in memory each turn); counted, 8 and 26.
  # Written out one by one: this run plays each test in a Ractor, which cannot run a method defined
  # from a block.
  def test_a_turn_of_repeat_set_costs_under_8_cycles = assert_turn_under(:repeat_set, 8)
  def test_a_turn_of_repeat_read_costs_under_30_cycles = assert_turn_under(:repeat_read, 30)
  def test_a_turn_of_while_set_costs_under_10_cycles = assert_turn_under(:while_set, 10)
  def test_a_turn_of_while_read_costs_under_30_cycles = assert_turn_under(:while_read, 30)

  # A search that asks each turn whether to `break` or go to its `next` round, a jump being one branch.
  # Measured: 67 and 64 a turn while a jump set a hidden number that the loop's test and a test round
  # the rest of the turn read; 12 and 47 as a branch. The `next` loop is not a counted while (its
  # `i += 1` is not last), so its turn is a while's, asking its test of `i` in memory.
  def test_a_turn_of_while_break_costs_under_14_cycles = assert_turn_under(:while_break, 14)
  def test_a_turn_of_while_next_costs_under_50_cycles = assert_turn_under(:while_next, 50)

  # A Ruby `times` folded into one loop, working four numbers out from its count each turn
  # (`k * 3 + 1`, `k * 5 + 2`, `k + 7`, `100 - k`). Measured: 38 a turn, each number read straight
  # from the count's register in one instruction with the number added (ADD with a shifted register,
  # RSB from a number); the same rounds written out cost 19 a round, a load, an add of a number and
  # a store each. The gap is the working out from the count, which a running number kept in a
  # register beside it would close.
  def test_a_turn_of_folded_steps_costs_under_42_cycles = assert_turn_under(:steps, 42)

  private def assert_turn_under(loop, bound)
    cost = LoopCostGames.cycles_a_turn(:gba, loop, FRAME_CYCLES)

    assert_operator cost, :<, bound, "a turn of #{loop} costs #{cost.round(1)} cycles"
  end
end
