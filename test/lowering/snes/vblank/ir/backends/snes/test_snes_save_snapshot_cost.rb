# frozen_string_literal: true

require "test_helper"
require "save_snapshot_cost_games"

# What a save's snapshot of a list costs on the Super Nintendo, measured in the emulator: a record
# keeping a list of 64 words, 256 bytes, copied into the record's buffer on the pass the save is asked
# (SaveSnapshotCostGames). Each run of the list's slots is one MVN (Lowering#emit_list_pack_block),
# seven cycles a byte (fullsnes, "65XX Block Move"): the opcode and its two banks fetched again, the
# byte read and written in work RAM, eight master clocks an access there and six a cycle inside
# (fullsnes, "SNES Memory Map": the slow speed), so at most about 52 master clocks a byte, 13,312 for
# these 256 with every fetch at the slow speed, besides the setting up.
class TestSNESSaveSnapshotCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # The budget for the list's 256 bytes: the block moves' master clocks above and half as much again,
  # room for the call that finds the runs and the test that the run fits. The loop the step stands
  # for is a list_get and a list_set a byte, each a call into the runtime, and far over it.
  LIST_CLOCKS = 20_000

  def test_a_list_of_64_words_costs_the_save_under_the_budget
    cost = SaveSnapshotCostGames.cycles_a_snapshot(:snes, FRAME_CLOCKS)

    assert_operator cost, :<, LIST_CLOCKS, "the list's 256 bytes cost #{cost.round} master clocks"
  end
end
