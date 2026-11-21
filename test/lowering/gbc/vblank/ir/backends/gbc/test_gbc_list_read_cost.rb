# frozen_string_literal: true

require "test_helper"
require "list_read_cost_games"

# A list read at a worked-out index on the Game Boy Color, `x = row[i]`, measured in the emulator: the
# index tested against the list's length, HL pointed at the slot, the slot read and its sign spread
# (KeptVariables#emit_list_slot_of_index, Lowering#emit_slot_widened_at_hl). The console's own code
# reads a byte with HL on it, LD A,[HL], two machine cycles (Pan Docs, "CPU Instruction Set"); a list
# is reached from a number instead, and VBlank's numbers are 32 bits, so a read pays for the index's
# load, the slot's address and the widening besides, and the test where the index is not known to be
# inside.
class TestGBCListReadCost < Minitest::Test
  # A frame's cycles at double speed: 154 lines of 912.
  FRAME_CYCLES = 140_448

  # Measured on lists of bytes: at a variable 108 cycles; at a mask written in the program 264 while
  # the mask was not known to keep the index inside (ControlFlow#index_known_below), 172 after; at a
  # loop's count 108, 88 once the count is known inside.
  BOUNDS = { variable: 115, mask: 185, count: 95 }.freeze

  # Measured on lists of halves, whose slots are read into all four bytes of a number: 248 at a
  # variable while the read called rt_read_int16, 192 with the read written in place; 228 at a loop's
  # count, 152 with no test as well.
  HALF_BOUNDS = { variable: 205, count: 165 }.freeze

  BOUNDS.each do |index, bound|
    define_method(:"test_a_read_at_a_#{index}_costs_under_#{bound}_cycles") do
      cost = ListReadCostGames.cycles_a_read(:gbc, index, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a read at a #{index} costs #{cost.round(1)} cycles"
    end
  end

  HALF_BOUNDS.each do |index, bound|
    define_method(:"test_a_read_of_halves_at_a_#{index}_costs_under_#{bound}_cycles") do
      cost = ListReadCostGames.cycles_a_read(:gbc, index, FRAME_CYCLES, width: :half)

      assert_operator cost, :<, bound, "a read of halves at a #{index} costs #{cost.round(1)} cycles"
    end
  end

  # The reads are the interpreter's on every pass, in each width.
  def test_the_reads_are_the_interpreters_on_every_pass
    %i[byte half word].each do |width|
      ListReadCostGames::READS_A_PASS.each_key do |index|
        game_player.run(ListReadCostGames.game(:gbc, index, width: width).program(console: :gbc), frames: 20)
      end
    end
  end
end
