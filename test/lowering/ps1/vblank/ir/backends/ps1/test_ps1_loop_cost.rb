# frozen_string_literal: true

require "test_helper"
require "loop_cost_games"

# A TURN OF A LOOP ON THE PLAYSTATION, measured in the emulator: a `repeat`, and a game's
# `while i < n` with `i += 1` last, which the build lowers as a counted loop (LoopForm#counted_while).
# The R3000's own way is a count in a register, ADDIU, a compare and a branch with its delay slot
# (psx-spx, "CPU Opcode Encoding"). A count here is kept in a saved register where the body cannot
# reach the game's routines (PS1::Lowering#with_counter_held), so a turn loads nothing from main RAM,
# which has no data cache. The bodies set a variable, `c = 1`, or read a list at the count.
class TestPS1LoopCost < Minitest::Test
  # A frame's CPU cycles at 33.8688 MHz.
  FRAME_CYCLES = 566_122

  # Measured: a repeat 10.4 a turn setting and 22.3 reading with its count in main RAM, 8.7 and 18.3 in
  # a register. A counted while was 21.6 and 35.6 while it was written as it reads (its hidden count
  # kept, `i` loaded to be compared and added to each turn); counted, in a register, 9.9 and 19.0.
  BOUNDS = { repeat_set: 10, repeat_read: 21, while_set: 11, while_read: 21 }.freeze

  BOUNDS.each do |loop, bound|
    define_method(:"test_a_turn_of_#{loop}_costs_under_#{bound}_cycles") do
      cost = LoopCostGames.cycles_a_turn(:ps1, loop, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a turn of #{loop} costs #{cost.round(1)} cycles"
    end
  end
end
