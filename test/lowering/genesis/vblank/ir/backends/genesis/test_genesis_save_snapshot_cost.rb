# frozen_string_literal: true

require "test_helper"
require "save_snapshot_cost_games"

# What a save's snapshot of a list costs on the Genesis, measured in the emulator: a record keeping a
# list of 64 words, 256 bytes, copied into the record's buffer on the pass the save is asked
# (SaveSnapshotCostGames). Each run of the list's slots is moved by Runtime::Lists' rt_list_pack: each
# of the 64 words is four MOVE.B -(An),(An)+ (14 cycles each, M68000 Family Programmer's Reference,
# "Move Byte and Word Instruction Execution Times") and four DBRA taken (10 each), with a few
# instructions around each item. That is about 120 cycles a word and 7,700 for the list, or about
# 54,000 master clocks at 7 a cycle.
class TestGenesisSaveSnapshotCost < Minitest::Test
  # A frame's master clocks: 262 lines of 3,420.
  FRAME_CLOCKS = VBlank::Console::GENESIS.cycles_a_frame

  # The budget for the list's 256 bytes: about twice the clocks above, room for the call, the fit test
  # and the measurement. The loop the step stands for is a list_get and a list_set a byte, each a call
  # into the runtime, and far over it.
  LIST_CLOCKS = 120_000

  def test_a_list_of_64_words_costs_the_save_under_the_budget
    cost = SaveSnapshotCostGames.cycles_a_snapshot(:genesis, FRAME_CLOCKS)

    assert_operator cost, :<, LIST_CLOCKS, "the list's 256 bytes cost #{cost.round} master clocks"
  end
end
