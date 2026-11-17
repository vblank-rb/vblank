# frozen_string_literal: true

require "test_helper"
require "loop_cost_games"

# A TURN OF A LOOP ON THE SUPER NINTENDO, measured in the emulator: a `repeat`, and a game's
# `while i < n` with `i += 1` last, which the build lowers as a counted loop (LoopForm#counted_while).
# The 65816's own way is a count in an index register, INY or DEX, a compare with the number and a
# branch back, a few cycles a turn (fullsnes and the SNESdev wiki's 65816 reference). A count below
# $8000 is counted in its low half (SNES::Lowering#with_counter_held), and in Y where only the loop
# reads it and nothing in the loop changes Y. The bodies set a variable, `c = 1`, or read a list at the
# count, which reads the count from work RAM.
class TestSNESLoopCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Measured: a repeat 236 a turn setting with its count an INC of work RAM, 156 counted in Y; 372
  # reading. A counted while was 775 and 996 while it was written as it reads (its hidden count kept,
  # `i` read and added to as 32 bits each turn); counted, 156 setting (in Y) and 372 reading.
  BOUNDS = { repeat_set: 170, repeat_read: 390, while_set: 170, while_read: 390 }.freeze

  BOUNDS.each do |loop, bound|
    define_method(:"test_a_turn_of_#{loop}_costs_under_#{bound}_master_clocks") do
      cost = LoopCostGames.cycles_a_turn(:snes, loop, FRAME_CLOCKS)

      assert_operator cost, :<, bound, "a turn of #{loop} costs #{cost.round(1)} master clocks"
    end
  end
end
