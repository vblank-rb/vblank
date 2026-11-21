# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# WHAT ASKING FOR A SAVE COSTS THE FRAME IT IS ASKED ON, measured in the emulator. Asking copies
# what the record keeps into a buffer of the record's own there and then (Builder::SaveJobs, "THE
# SAVE HOLDS THE MOMENT IT WAS ASKED FOR"), and the buffer is written over the passes after. A list
# of 128 words is 512 bytes of that copy. Its items go in as one step (IR list_pack), which the
# Advance moves with its copy engine a word at a time (GBA::Lists#emit_list_pack): a read of quick
# memory and a write of the roomy memory a word, about seven cycles (GBATEK, "Memory Timings": a
# 32-bit access to the roomy memory takes six), so under a thousand for these 128.
#
# The cost of the list is the frame of a build whose list is full, less the same frame of the same
# game with the list empty, so the rest of the asking (the queue, the variables) is in both.
class TestSaveJobsSnapshotCost < Minitest::Test
  include EmulatorSupport

  def setup
    require_emulator!
  end

  ITEMS = 128

  # The budget for the list's 512 bytes on the frame of the save: twice the copy engine's cost, room
  # for the few instructions around the copy. A byte at a time, each shifted and set, is several
  # instructions a byte and far over it.
  LIST_CYCLES = 2_000

  # A game that saves a file of three numbers and a list of 128 words when A is pressed, the list
  # full of nought, or with +full+ false empty.
  private def saving_game(full:)
    VBlank.game("SNAPSHOT", consoles: %i[gba]) do
      screen :bitmap
      hearts = var :hearts, 3
      coins = var :coins, 10
      room = var :room, 2
      flags = list :flags, capacity: TestSaveJobsSnapshotCost::ITEMS, width: :word, full_of: full ? 0 : nil
      files = save_data(:file, copies: 2) { keep hearts, coins, room, flags }
      game_loop do
        files[0].save if pressed(:a)
      end
    end
  end

  # The cycles of the frame A is first pressed on, a few frames after power-on: the larger of the
  # processor's and the frame's own, since the processor stands still while the copy engine works
  # (RubyGBAEmulator::Probe::FrameCost).
  private def save_frame_cycles(game)
    rom = game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new, profile: false)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "snapshot.gba")
      rom.write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      begin
        cost = probe.frame_cost(settle: 10, keys: nil)
        idle = [cost.busy_cycles, cost.active_cycles].max
        cost = probe.frame_cost(keys: [:a])
        [[cost.busy_cycles, cost.active_cycles].max, idle]
      ensure
        probe.close
      end
    end
  end

  def test_a_list_of_128_words_costs_the_frame_of_the_save_under_the_budget
    full, idle = save_frame_cycles(saving_game(full: true))
    empty, = save_frame_cycles(saving_game(full: false))

    assert_operator empty, :>, idle, "the frame A is pressed on asks for the save"
    assert_operator full - empty, :<, LIST_CYCLES, "the list's 512 bytes cost #{full - empty} cycles on the frame of the save"
  end
end
