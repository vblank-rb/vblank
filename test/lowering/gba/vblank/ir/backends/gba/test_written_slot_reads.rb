# frozen_string_literal: true

require "test_helper"
require "list_read_cost_games"

# A list's slot named by a number written in the program, `x += a[1]`, on the Advance: the slot's
# place is known as the code is written, so the read is one load at a distance, as a variable's is.
# A small list read only so is kept beside the variables (Lists#near_list?), and the load is then
# from the variables' own base (Primitives#emit_fixed_slot_base), with no base of the list's own
# loaded first. Measured in what the build emitted, since each read is a straight run of
# instructions (.claude/testing/costs.md).
class TestWrittenSlotReads < Minitest::Test
  def test_a_read_of_a_written_slot_emits_what_a_variable_read_emits
    written = emitted_bytes(:written)
    named = emitted_bytes(:named)

    assert_equal named, written, "four written slots read take #{written} bytes, four variables #{named}"
  end

  private def emitted_bytes(index)
    program = ListReadCostGames.game(:gba, index, width: :word).program(console: :gba)
    GBA.new.lower(program).bytesize
  end
end
