# frozen_string_literal: true

require "test_helper"
require "loop_cost_games"

# A turn of a loop on the Genesis, measured in the emulator: a `repeat`, and a game's `while i < n`
# with `i += 1` last, which the build lowers as a counted loop (LoopForm#counted_while). The 68000's
# own way is a count in a data register, ADDQ and CMP on it and a branch, or DBF, 10 cycles a turn
# taken (68000 timing tables, "Miscellaneous Instruction Execution Times"). A turn here keeps its count
# in a data register where the body allows (Genesis::Lowering#with_counter_held), adds one, compares
# and branches; the bodies are a long written to work RAM, `c = 1` (MOVE.L #1 to an absolute long, 28
# cycles), or a list read at the count.
class TestGenesisLoopCost < Minitest::Test
  # A frame's 68000 cycles: 262 lines of 488.
  FRAME_CYCLES = 262 * 488

  # Measured: a repeat 57 a turn setting, 87 reading. A counted while was 118 and 181 while it was
  # written as it reads (its hidden count kept, `i` read and added to in work RAM each turn); counted,
  # 58 and 88. A search asking each turn whether to `break` or go to its `next` round was 398 and 290
  # while a jump set a hidden number the loop's test and the rest of the turn read; 158 and 266 with a
  # jump that is a branch, the count in work RAM; 120 and 239 with the count in a data register (the
  # `next` loop is a while that is not counted).
  BOUNDS = { repeat_set: 62, repeat_read: 95, while_set: 62, while_read: 95, while_break: 130, while_next: 255 }.freeze

  BOUNDS.each do |loop, bound|
    define_method(:"test_a_turn_of_#{loop}_costs_under_#{bound}_cycles") do
      cost = LoopCostGames.cycles_a_turn(:genesis, loop, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a turn of #{loop} costs #{cost.round(1)} cycles"
    end
  end
end
