# frozen_string_literal: true

require "test_helper"
require "list_read_cost_games"

# A list read at a worked-out index on the Super Nintendo, `x = row[i]`, measured in the emulator: the
# index's two halves tested against the list's length, its low half scaled into X, the slot read
# with X and its sign spread into the variable (SNES::Lowering#emit_slot_into_x,
# #emit_slot_into_variable). No routine is called: the call to the runtime's list routine is only
# on the way to stopping the game, for an index outside the list. The console's own code reads a
# field with the thing's offset already in X, one LDA abs,X; a list is reached from a 32-bit index
# instead, held in work RAM, which the console reads at its slow speed (fullsnes, "SNES Memory
# Map").
class TestSNESListReadCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Measured on lists of bytes: at a variable 340 master clocks while the index was tested against the
  # length kept in the list's header, 318 against the capacity written in the instruction
  # (SNES::Lowering#full_length_at); at a mask written in the program 602, 504 with no test once the
  # mask is known to keep the index inside (ControlFlow#index_known_below); at a loop's count 340, 232
  # once the count is known inside, X set once for the four lists of one width.
  BOUNDS = { variable: 330, mask: 520, count: 250 }.freeze

  BOUNDS.each do |index, bound|
    define_method(:"test_a_read_at_a_#{index}_costs_under_#{bound}_master_clocks") do
      cost = ListReadCostGames.cycles_a_read(:snes, index, FRAME_CLOCKS)

      assert_operator cost, :<, bound, "a read at a #{index} costs #{cost.round(1)} master clocks"
    end
  end

  # The reads are the interpreter's on every pass.
  def test_the_reads_are_the_interpreters_on_every_pass
    ListReadCostGames::READS_A_PASS.each_key do |index|
      game_player.run(ListReadCostGames.game(:snes, index, width: :half).program(console: :snes), frames: 20)
    end
  end
end
