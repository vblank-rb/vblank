# frozen_string_literal: true

require "test_helper"
require "list_read_cost_games"

# A LIST READ AT A WORKED-OUT INDEX ON THE GENESIS, `x = row[i]`, measured in the emulator: the index
# read, A0 pointed at the list, the index tested against its length, scaled, the slot read, widened
# and stored (Genesis::Lowering#emit_slot_address). The console's own code reads a field of a record
# it holds the address of in one MOVE with a 16-bit displacement, 12 cycles for a byte or a word and
# 16 for a long (68000 timing tables, "Move Byte and Word Instruction Execution Times"); a list is
# reached from a number instead, so a read pays for the index's load, the slot's address and the
# store besides, and the test where the index is not known to be inside.
class TestGenesisListReadCost < Minitest::Test
  # A frame's 68000 cycles: 262 lines of 488.
  FRAME_CYCLES = 262 * 488

  # Measured on lists of bytes: at a variable 83 cycles, its test 20 of them (MOVEQ, CMP.L and the
  # branch over the jump to the fault); at a mask written in the program 103 while the mask was not
  # known to keep the index inside (ControlFlow#index_known_below), 83 after; at a loop's count, held
  # in a register and known inside, 51.
  BOUNDS = { variable: 90, mask: 90, count: 56 }.freeze

  BOUNDS.each do |index, bound|
    define_method(:"test_a_read_at_a_#{index}_costs_under_#{bound}_cycles") do
      cost = ListReadCostGames.cycles_a_read(:genesis, index, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a read at a #{index} costs #{cost.round(1)} cycles"
    end
  end

  # The reads are the interpreter's on every pass.
  def test_the_reads_are_the_interpreters_on_every_pass
    ListReadCostGames::READS_A_PASS.each_key do |index|
      game_player.run(ListReadCostGames.game(:genesis, index, width: :half).program(console: :genesis), frames: 20)
    end
  end
end
