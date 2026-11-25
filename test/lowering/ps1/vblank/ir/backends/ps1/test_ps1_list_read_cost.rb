# frozen_string_literal: true

require "test_helper"
require "list_read_cost_games"

# A list read at a worked-out index on the PlayStation, `x = row[i]`, measured in the emulator: the
# index tested against the list's length, shifted by the slot's width, added to the list's place and
# the slot loaded (PS1::Lowering#emit_slot_place). The console's own code loads a field of a record
# it holds the address of with one LW, LH or LB at a 16-bit offset (psx-spx, "CPU Load/Store
# Opcodes"); a list is reached from a number instead, so a read pays for the index's load, the
# slot's address and the store besides, and the test where the index is not known to be inside.
class TestPS1ListReadCost < Minitest::Test
  # A frame's cycles: 33.8688 MHz over 59.83 frames a second.
  FRAME_CYCLES = 566_122

  # Measured on lists of bytes made as the game starts, so always full: at a variable 25 cycles; at
  # a mask written in the program 31.5 while the mask was not known to keep the index inside
  # (ControlFlow#index_known_below), 21.4 after; at a loop's count 19.3, 14.9 once the count is known
  # inside.
  BOUNDS = { variable: 28, mask: 25, count: 17 }.freeze

  BOUNDS.each do |index, bound|
    define_method(:"test_a_read_at_a_#{index}_costs_under_#{bound}_cycles") do
      cost = ListReadCostGames.cycles_a_read(:ps1, index, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a read at a #{index} costs #{cost.round(1)} cycles"
    end
  end

  # A slot named by a number written in the program, `x += a[1]`, is one load at an address known as
  # the code is written, with no check (PS1::Lowering#fixed_slot_address), straight into the register
  # the sum wants (#emit_load_simple). Measured: 18 cycles a read. Of these four lists of 32 words
  # only the first fits the room the scratchpad keeps for lists (#place_list), so three of the four
  # loads wait on main RAM; a variable, kept in the scratchpad, costs next to nothing.
  WRITTEN_SLOT_BOUND = 21

  def test_a_read_of_a_written_slot_costs_under_its_bound
    cost = ListReadCostGames.cycles_a_read(:ps1, :written, FRAME_CYCLES, width: :word)

    assert_operator cost, :<, WRITTEN_SLOT_BOUND, "a written slot costs #{cost.round(1)} cycles"
  end

  # The reads are the interpreter's on every pass.
  def test_the_reads_are_the_interpreters_on_every_pass
    ListReadCostGames::READS_A_PASS.each_key do |index|
      game_player.run(ListReadCostGames.game(:ps1, index, width: :half).program(console: :ps1), frames: 20)
    end
  end
end
