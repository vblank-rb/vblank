# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# What asking for a save costs the frame it is asked on, measured in the emulator. Asking copies
# what the record keeps into a buffer of the record's own there and then (Builder::SaveJobs, "the
# save holds the moment it was asked for"), and the buffer is written over the passes after. A list
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
  #
  # With +ring+ the game drops from the front of the list once, so it is a ring. With +odd_before+
  # a list of that many bytes is kept first, so the words that follow do not start on a whole word
  # in the record.
  private def saving_game(full:, ring: false, odd_before: 0)
    VBlank.game("SNAPSHOT", consoles: %i[gba]) do
      screen :bitmap
      hearts = var :hearts, 3
      coins = var :coins, 10
      room = var :room, 2
      lead = list :lead, capacity: odd_before, width: :byte, full_of: 0 if odd_before.positive?
      flags = list :flags, capacity: TestSaveJobsSnapshotCost::ITEMS, width: :word, full_of: full ? 0 : nil
      files = save_data(:file, copies: 2) { odd_before.positive? ? keep(hearts, coins, room, lead, flags) : keep(hearts, coins, room, flags) }
      game_loop do
        flags.shift if ring && full && pressed(:b)
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

  # A ring's items are two runs of memory, each moved by the copy engine like a plain list's, so a ring
  # costs what a plain list does: it took 27,000 cycles one byte at a time.
  def test_a_ring_list_costs_the_frame_of_the_save_what_a_plain_one_does
    full, = save_frame_cycles(saving_game(full: true, ring: true))
    empty, = save_frame_cycles(saving_game(full: false, ring: true))

    assert_operator full - empty, :<, LIST_CYCLES, "the ring's 512 bytes cost #{full - empty} cycles on the frame of the save"
  end

  # The copy engine writes whole words or half-words only, so a list that starts on an odd byte of the
  # record is written by the processor, each word written joined from two read
  # (Lists#emit_copy_to_odd_address), four at a time: about three times the engine's cost, where a
  # byte at a time took 15,000 cycles.
  UNALIGNED_LIST_CYCLES = 3_500

  def test_a_list_after_an_odd_number_of_bytes_costs_about_three_plain_ones
    full, = save_frame_cycles(saving_game(full: true, odd_before: 3))
    empty, = save_frame_cycles(saving_game(full: false, odd_before: 3))

    assert_operator full - empty, :<, UNALIGNED_LIST_CYCLES, "the list's 512 bytes cost #{full - empty} cycles on the frame of the save"
  end
end
