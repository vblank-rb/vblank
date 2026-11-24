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

  # The build measures its routines in a pass of its own before it lowers the game for real, and
  # where a variable or a list lands decides what reaching it costs. So the two passes lay the
  # quick memory out alike, the lists kept beside the variables included, or a routine can come
  # out bigger than it was measured.
  def test_the_measuring_pass_and_the_build_lay_out_memory_alike
    program = ListReadCostGames.game(:gba, :written, width: :word).program(console: :gba)
    measured = GBA.new
    measured.lower(program, fast_funcs: Set.new)
    built = GBA.new
    built.lower(program)

    assert_equal list_bases(measured, program), list_bases(built, program)
    assert_equal measured.var_addresses.slice(:x, :t, :i), built.var_addresses.slice(:x, :t, :i)
  end

  private def list_bases(backend, program)
    backend.build_record(program).lists.slice(:a, :b, :c, :d).transform_values(&:base)
  end

  private def emitted_bytes(index)
    program = ListReadCostGames.game(:gba, index, width: :word).program(console: :gba)
    GBA.new.lower(program).bytesize
  end
end
