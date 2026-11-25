# frozen_string_literal: true

require "test_helper"
require "save_snapshot_cost_games"

# What a save's snapshot of a list costs on the Game Boy Color, measured in the emulator: a record
# keeping a list of 64 words, 256 bytes, copied into the record's buffer on the pass the save is asked
# (SaveSnapshotCostGames). The runtime copies the run (Runtime::Lists#emit_list_pack): LD A,(DE),
# LD (HL+),A, INC DE, DEC BC, LD A,B, OR C and JR NZ, thirteen machine cycles a byte (Pan Docs, "CPU
# Instruction Set"), four of the profiler's cycles each at double speed, so about 52 a byte and
# 13,312 for these 256, besides the setting up.
class TestGBCSaveSnapshotCost < Minitest::Test
  # A frame's cycles at double speed: 154 lines of 912.
  FRAME_CYCLES = 140_448

  # The budget for the list's 256 bytes: the copy's cycles above and half as much again, room for the
  # setting up around it and the test that the run fits. The loop the step stands for is a list_get
  # and a list_set a byte, each a call into the runtime, and far over it.
  LIST_CYCLES = 20_000

  def test_a_list_of_64_words_costs_the_save_under_the_budget
    cost = SaveSnapshotCostGames.cycles_a_snapshot(:gbc, FRAME_CYCLES)

    assert_operator cost, :<, LIST_CYCLES, "the list's 256 bytes cost #{cost.round} cycles"
  end
end
