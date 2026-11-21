# frozen_string_literal: true

require "test_helper"
require "all/vblank/ir/test_list_packing"

# A LIST'S ITEMS WRITTEN INTO A LIST OF BYTES IN ONE STEP (IR list_pack) means exactly the loop it
# stands for (IR::ListPacking.loops_for): the same bytes, and the count left at nought. The
# interpreter runs the step itself, so this holds its own reading of the step to the loop every
# backend without a block copy of its own lowers.
class TestListPackingLoops < Minitest::Test
  include ListPackingPrograms

  # +program+ with its list_pack written out as its loop.
  private def as_loops(program)
    steps = program.children.flat_map do |node|
      node.kind == :list_pack ? VBlank::IR::ListPacking.loops_for(node) : [node]
    end
    program(*steps.map(&:copy))
  end

  def test_the_step_is_the_loop_it_stands_for
    CASES.each do |name, (width, items, at, ring)|
      whole = Reference.new.run(packed(width, items, at, ring), frames: 2)
      loops = Reference.new.run(as_loops(packed(width, items, at, ring)), frames: 2)

      assert_equal loops.list(:bytes), whole.list(:bytes), "the #{name} case"
      assert_equal loops[:count], whole[:count], "the #{name} case's count"
    end
  end

  # A run reaching past the list it writes into stops at the same slot either way, with the bytes
  # before it written and the count where the loop had got to.
  def test_a_run_past_the_end_stops_where_the_loop_stops
    stopped = [false, true].map do |loops|
      program = packed(:word, [0x0102, 0x0304], 12, false)
      player = Reference.new
      error = assert_raises(VBlank::IR::ProgramError) { player.run(loops ? as_loops(program) : program, frames: 2) }
      [error.message, player.list(:bytes), player[:count]]
    end

    assert_equal stopped.last, stopped.first
    assert_equal [2, 1], stopped.first[1][12, 2], "the bytes inside the list are written"
  end
end
