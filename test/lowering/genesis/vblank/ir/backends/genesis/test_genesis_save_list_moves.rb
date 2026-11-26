# frozen_string_literal: true

require "save_list_move_tests"
require "stringio"

# The Genesis's own routines for a whole list moved to or from save memory (Runtime::Saving), held to
# the interpreter (SaveListMoveTests).
class TestGenesisSaveListMoves < Minitest::Test
  include SaveListMoveTests

  Genesis = VBlank::IR::Backends::Genesis

  private def moved_on = :genesis
  private def checked_run = Genesis::CheckedRun

  def test_a_list_move_is_one_call_into_the_runtime
    rom = Genesis.new.build(round_the_ring(:word, at: 0x400, count: 5))

    assert_includes rom.built.code.keys, "rt_save_store_list"
    assert_includes rom.built.code.keys, "rt_save_load_list"
  end

  # A list of 128 words stored once, after eleven waits: the store lands in the one frame measured (the first
  # after ten settling frames) with eleven and in no other number of waits from 4 to 14, which was tried. No retail game's save routine is measured; the budget is the per-byte
  # loop from the 68000's documented timings (M68000 User's Manual, instruction execution times): move.b
  # -(a0),(a1) 14 cycles, addq.l #2,a1 8, dbra 10, so 32 cycles a byte, 7 core cycles each in Genesis Plus GX,
  # and 3420 of them a line: 512 bytes are about 34 lines, and the step from one item to the next is
  # allowed on top, 48 lines in all.
  def test_storing_a_list_of_128_words_costs_no_more_than_its_byte_loop
    program = program(set(:slot, 0), set(:n, 0), list_new(:kept, 128, width: :word),
                      repeat(int(128), :n, list_push(:kept, int(7))),
                      *Array.new(11) { wait_vblank },
                      save_store_list(:kept, at: 0, width: :word, index: :slot),
                      loop_(wait_vblank), console: :genesis)
    rows = Genesis.new.build(program).profile(out: StringIO.new, settle: 10, frames: 1).runtime
    lines = rows.select { |row| row.routine.to_s.match?(/rt_save_store_list/) }.sum { |row| row.share * 262 }

    assert_operator lines, :>, 0, "the store landed in the measured frame"
    assert_operator lines, :<, 48, "storing 128 words took #{lines.round(2)} lines of the picture"
  end
end
