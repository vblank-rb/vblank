# frozen_string_literal: true

require "test_helper"

# The emitter's label table holds Symbols only, whichever kind a caller wrote a name in. A table
# holding both finds nothing when asked in the other kind, and says nothing about it.
class TestEmitLabels < Minitest::Test
  A = VBlank::IR::Backends::GBA::ASM
  Emit = VBlank::IR::Backends::GBA::Emit
  DerivedNames = VBlank::IR::Backends::DerivedNames

  def test_a_label_placed_as_a_string_is_kept_as_a_symbol
    emitter = Emit.new
    emitter.emit(A.nop)
    emitter.place_label("there")

    assert_equal({ there: 4 }, emitter.labels)
    assert_equal 4, emitter.label_offset(:there)
  end

  def test_a_jump_written_with_either_kind_reaches_the_same_label
    by_string = Emit.new
    by_string.emit_branch(:b, "there")
    by_string.place_label(:there)
    by_string.resolve_fixups

    by_symbol = Emit.new
    by_symbol.emit_branch(:b, :there)
    by_symbol.place_label("there")
    by_symbol.resolve_fixups

    assert_equal by_symbol.code, by_string.code
  end

  def test_a_routine_measures_from_its_label_to_its_end_label
    emitter = Emit.new
    emitter.place_label(:work)
    3.times { emitter.emit(A.nop) }
    emitter.place_label(DerivedNames.routine_end(:work))

    assert_equal 12, emitter.routine_bytes("work")
  end

  def test_a_label_never_placed_is_refused_by_name
    error = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { Emit.new.label_offset(:nowhere) }

    assert_match "nowhere", error.message
  end
end
