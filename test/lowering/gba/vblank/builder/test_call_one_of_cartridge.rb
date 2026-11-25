# frozen_string_literal: true

require "test_helper"
require "stringio"
require "all/vblank/builder/test_call_one_of"

# A call picked by number on the Advance's cartridge: that the cartridge reaches the routine the
# number picks wherever it was put, and what picking costs — which does not grow with the length
# of the list. That it picks the right routine on every run, and what it refuses, is in
# test/all/vblank/builder/test_call_one_of.rb.
class TestCallOneOfCartridge < Minitest::Test
  include CallOneOfGames

  # A script format's worth of instructions — the size the real case is.
  MANY = 139

  # How many dispatches a frame the measuring programs make.
  DISPATCHES = 16

  # The table holds where each routine really runs, which is not the same place for all of
  # them: one kept in the console's quick memory was copied there at boot, and one left in the
  # cartridge never moves. Both are reached through the same table, so a build that wrote the
  # cartridge's address for the moved routine would jump into whatever else was there.
  def test_a_routine_in_the_quick_memory_and_one_in_the_cartridge_are_both_reached
    rom = VBlank.build("PICKFAST", console: :gba, code: "BPK2", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      moved = 0
      left = 0
      here = var :here, 0
      there = var :there, 1
      b = self
      b.func(:in_quick_memory, fast: true) { moved += 1 }
      b.func(:in_cartridge, fast: false) { left += 1 }
      game_loop do
        b.call %i[in_quick_memory in_cartridge], number: here
        b.call %i[in_quick_memory in_cartridge], number: there
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_operator v.var(:moved), :>, 0, "the routine kept in the quick memory was reached"
    assert_operator v.var(:left), :>, 0, "...and so was the one left in the cartridge"
  end

  # A Hash is laid out as a table from its first key to its last, a key below 0 taken off the
  # number first and a gap held by a routine that does nothing. Each number lands on its own
  # routine, and a gap, a number past the last key and one below the first call nothing.
  def test_a_hash_with_a_gap_and_a_key_below_nought_reaches_each_routine
    rom = VBlank.build("PICKHASH", console: :gba, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      low = 0
      high = 0
      picks = %i[pick_low pick_gap pick_high pick_past pick_below].zip([-1, 0, 1, 2, -2]).map { |name, n| var name, n }
      b = self
      b.func(:on_low) { low += 1 }
      b.func(:on_high) { high += 10 }
      game_loop { picks.each { |pick| b.call({ -1 => :on_low, 1 => :on_high }, number: pick) } }
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_operator v.var(:low), :>, 0
    assert_equal v.var(:low) * 10, v.var(:high), "each pass called each routine once, and nothing else"
  end

  # A list too long for its length to ride inside an instruction. The console can carry a
  # number up to 255 in the compare that holds the call back, and a longer list has to put its
  # length in a register first. 257 is the first length that needs it.
  def test_a_list_longer_than_a_number_can_ride_in_an_instruction
    names = (0...257).map { |i| :"op#{i}" }
    rom = VBlank.build("PICKLONG", console: :gba, code: "BPK4", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = 0
      last = var :last, 256
      past = var :past, 257
      names.each_with_index { |name, i| func(name) { n = i } }
      b = self
      game_loop do
        b.call names, number: last
        b.call names, number: past
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_equal 256, v.var(:n), "the last routine of 257 ran, and the number past the end called nothing"
  end

  # ...and the address in the table is where the routine really runs. A routine kept in the
  # quick memory is also left in the cartridge, where boot copied it from, and that copy runs
  # perfectly well — about two and a half times slower. So calling the wrong one of the two is
  # not a broken game, it is a game that quietly lost the speed it was given the memory for.
  # What says which one ran is a measurement: the profile finds the routine where it really is.
  def test_a_routine_picked_by_number_runs_where_it_was_put
    rom = VBlank.build("PICKWHERE", console: :gba, code: "BPK5", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = 0
      which = var :which, 0
      b = self
      b.func(:busy, fast: true) { b.repeat(200) { n += 1 } }
      game_loop { b.call [:busy], number: which }
    end
    busy = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false).lines.find { |line| line.name == :busy }

    refute_nil busy, "the frame is spent in :busy, so the profile has to find it"
    assert_equal :quick_memory, busy.where
    assert_operator busy.share, :>, 50, "and that is where the frame went"
  end

  # A loop around it has to give up the two registers it would otherwise count in, exactly as a
  # plain call does — so this pins that the loop still counts right on the console.
  def test_a_loop_around_it_counts_right_on_the_console
    rom = VBlank.build("PICKLOOP", console: :gba, code: "BPK3", maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      passes = 0
      hits = 0
      b = self
      b.func(:one) { hits += 1 }
      b.func(:two) { hits += 10 }
      game_loop do
        passes = 0
        hits = 0
        b.repeat(4) do |i|
          b.call %i[one two], number: i % 2
          passes += 1
        end
        b.halt
      end
    end
    v = assert_emulator_loads_rom(rom, frames: 8, vars: rom.var_addresses)

    assert_equal 4, v.var(:passes), "the loop made its four passes"
    assert_equal 22, v.var(:hits), "...calling each routine twice"
  end

  # --- what it costs ---

  # The whole point: a list of a hundred and thirty-nine costs what a list of two does. A
  # dispatch that asked each name in turn would cost seventy times as much at that length.
  def test_the_cost_does_not_grow_with_the_length_of_the_list
    few = measure(dispatch_rom(2, code: "BPC1"))
    many = measure(dispatch_rom(MANY, code: "BPC2"))

    assert_in_delta few, many, few * 0.05,
                    "picking from #{MANY} routines cost #{many} instructions a frame against " \
                    "#{few} for picking from 2"
  end

  # ...and against what a game writes today: a test per routine, every one of them asked on
  # every dispatch.
  def test_it_beats_asking_each_routine_in_turn
    picked = measure(dispatch_rom(MANY, code: "BPC3"))
    asked = measure(chain_rom(MANY, code: "BPC4"))

    assert_operator asked, :>, picked * 5,
                    "asking each of #{MANY} routines in turn cost #{asked} instructions a frame " \
                    "against #{picked} for picking one"
  end

  # Two calls picking from the same list share one table, so the second costs the handful of
  # instructions that read it and none of the words — a table of 139 routines being 556 bytes
  # of the cartridge, per call, if each kept its own.
  def test_two_calls_picking_from_the_same_list_share_one_table
    one = GBA.new.lower(picking_program(1)).bytesize
    two = GBA.new.lower(picking_program(2)).bytesize

    assert_operator two - one, :<, MANY * 4,
                    "a second call picking from the same list grew the code by a whole table"
  end

  # +sites+ separate calls, all picking from one list of MANY routines.
  private def picking_program(sites)
    names = (0...MANY).map { |i| :"op#{i}" }
    program_with do
      screen :bitmap
      n = 0
      which = var :which, 0
      names.each { |name| func(name) { n += 1 } }
      b = self
      game_loop { sites.times { b.call names, number: which } }
    end
  end

  # A game that dispatches DISPATCHES times a frame, picking from +count+ routines by a number
  # read out of a table — so the number is worked out as it runs, as a script's would be.
  private def dispatch_rom(count, code:, dispatches: DISPATCHES)
    names = (0...count).map { |i| :"op#{i}" }
    VBlank.build("PICKCOST", console: :gba, code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = 0
      steps = table :steps, (0...dispatches).map { |i| (i * 37) % count }
      names.each { |name| func(name) { n += 1 } }
      b = self
      game_loop { b.repeat(dispatches) { |i| b.call names, number: steps[i] } }
    end
  end

  # The same game written the way it has to be written without this: one test per routine, and
  # every one of them asked on every dispatch.
  private def chain_rom(count, code:)
    names = (0...count).map { |i| :"op#{i}" }
    VBlank.build("PICKCHAIN", console: :gba, code: code, maker: "01", out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      n = 0
      op = 0
      steps = table :steps, (0...DISPATCHES).map { |i| (i * 37) % count }
      names.each { |name| func(name) { n += 1 } }
      b = self
      game_loop do
        b.repeat(DISPATCHES) do |i|
          op = steps[i]
          names.each_with_index { |name, k| b.call name if op == k }
        end
      end
    end
  end

  # Instructions a frame, measured on a real run. Each of these games sleeps out the rest of
  # its frame, so what is counted is the work and not the waiting.
  private def measure(rom)
    result = VBlank::Diagnostics::Profiler.run(rom, frames: 30, picture: false)
    refute result.dropping_frames?,
           "this measurement only compares like with like while both games keep up (#{result.fps} fps)"
    result.samples_per_frame
  end
end
