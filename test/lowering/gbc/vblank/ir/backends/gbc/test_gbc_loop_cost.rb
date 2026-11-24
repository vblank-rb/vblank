# frozen_string_literal: true

require "test_helper"
require "loop_cost_games"

# A turn of a loop on the Game Boy Color, measured in the emulator: a `repeat`, and a game's
# `while i < n` with `i += 1` last, which the build lowers as a counted loop (LoopForm#counted_while).
# The SM83's own way is a count of a byte in a register, DEC and a JR NZ back, four machine cycles a
# turn taken (Pan Docs, "CPU Instruction Set"). VBlank's numbers are 32 bits in memory, so a count is
# kept in one byte only where it is proven never to leave one (GBC::ByteVariables): a repeat's
# count below 128, and a counted while's variable below a limit that is. The bodies set a variable,
# `c = 1`, or read a list at the count.
class TestGBCLoopCost < Minitest::Test
  # A frame's cycles at double speed: 154 lines of 912.
  FRAME_CYCLES = 140_448

  # Measured: a repeat 180 a turn setting, 252 reading. A counted while was 536 and 700 while it was
  # written as it reads (its hidden count kept, `i` read and added to as four bytes each turn);
  # counted, with `i` a byte, 180 and 252. A search asking each turn whether to `break` or go to its
  # `next` round was 744 and 816 while a jump set a hidden number the loop's test and the rest of the
  # turn read; 220 and 756 with a jump that is a branch (the `next` loop is a while that is not counted).
  BOUNDS = { repeat_set: 195, repeat_read: 270, while_set: 195, while_read: 270, while_break: 240, while_next: 830 }.freeze

  BOUNDS.each do |loop, bound|
    define_method(:"test_a_turn_of_#{loop}_costs_under_#{bound}_cycles") do
      cost = LoopCostGames.cycles_a_turn(:gbc, loop, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a turn of #{loop} costs #{cost.round(1)} cycles"
    end
  end
end
