# frozen_string_literal: true

require "test_helper"
require "vblank/testing/in_ractors"

# A game's test helper plays its tests in Ractors by including Testing::InRactors, which freezes
# every fixture a test class keeps in a constant, so a test in a Ractor can read it.
class TestInRactors < Minitest::Test
  # Its tests declare classes, which changes the whole process.
  runs_on_the_main_ractor!

  private def fixture_holder = Class.new.extend(VBlank::Testing::InRactors::FrozenConstants)

  def test_a_fixture_in_a_constant_is_frozen_all_the_way_down
    holder = fixture_holder
    holder.const_set(:ROWS, [+"####", { colors: [+"red"] }])

    assert Ractor.shareable?(holder::ROWS)
    assert_equal [+"####", { colors: [+"red"] }], holder::ROWS
  end

  def test_code_and_streams_are_left_alone
    holder = fixture_holder
    holder.const_set(:OUT, $stdout)
    holder.const_set(:Helper, Module.new)

    refute holder::OUT.frozen?
    refute holder::Helper.frozen?
  end

  def test_a_block_that_cannot_be_shared_is_left_as_it_was
    holder = fixture_holder
    around = 1
    holder.const_set(:READ, -> { around })

    refute Ractor.shareable?(holder::READ)
  end

  def test_a_fixture_read_once_is_made_once_in_a_ractor
    made = 0
    holder = Class.new.extend(VBlank::Testing::InRactors::ReadOnce)

    2.times { holder.read_once(:console) { made += 1 } }

    assert_equal 1, made
  end

  def test_this_suite_plays_with_it
    assert_includes Minitest::Test.singleton_class.ancestors, VBlank::Testing::InRactors::FrozenConstants
    assert_respond_to TestInRactors, :read_once
  end
end
