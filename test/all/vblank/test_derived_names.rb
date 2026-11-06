# frozen_string_literal: true

require "test_helper"

# A lowering names many labels, tables and numbers after the thing they belong to. Spelt out at
# each call, as a Symbol that starts by interpolating the other name, a misspelt suffix makes a
# second name nothing else uses, and the call site reads as noise. Such a name is made once:
# by IR::Backends::DerivedNames, or in a constant beside its routine. This fails on a Symbol in the
# lowerings that starts with another name interpolated, so the count stays at nought. A fixed
# prefix followed by a run-time part (`:"__music_note_#{lane}"`) is a family of its own, not a
# name made from another, and is not counted.
class TestDerivedNames < Minitest::Test
  BACKENDS = VBlank.root.join("lib", "vblank", "ir", "backends").to_s

  # A Symbol literal whose first part is another name interpolated: `:"#{ROUTINE}_end"`.
  BUILT_FROM_ANOTHER_NAME = ':"#{'

  private def hand_built_names
    Dir.glob("#{BACKENDS}/**/*.rb").flat_map do |path|
      File.foreach(path).with_index(1).filter_map do |line, number|
        "#{path.delete_prefix("#{BACKENDS}/")}:#{number}  #{line.strip}" if line.include?(BUILT_FROM_ANOTHER_NAME)
      end
    end
  end

  def test_no_lowering_builds_a_name_from_another_by_hand
    found = hand_built_names

    assert_empty found, "These lines build a name from another name by hand. Use " \
                        "DerivedNames.routine_end, DerivedNames.sub_label or DerivedNames.join, or a " \
                        "constant beside the routine (lib/vblank/ir/backends/derived_names.rb):\n#{found.join("\n")}"
  end

  def test_derived_names_are_symbols_spelt_as_the_parts_say
    names = VBlank::IR::Backends::DerivedNames

    assert_equal :__mix_routine_end, names.routine_end(:__mix_routine)
    assert_equal :__fill_face_routine_out, names.sub_label("__fill_face_routine", :out)
    assert_equal :"game.timer3", names.local_number_name(nil, :timer, 3)
    assert_equal :"walk.column1", names.local_number_name(:walk, "column", 1)
    assert_equal :sprite__head, names.join(:sprite, "__head")
  end
end
