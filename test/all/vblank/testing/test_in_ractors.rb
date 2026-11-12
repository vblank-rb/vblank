# frozen_string_literal: true

require "test_helper"
require "vblank/testing/in_ractors"
require "json"
require "objspace"
require "tmpdir"

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

  # A FIXTURE STRING WRITTEN TO A FILE IS LEFT AS IT WAS. Ruby writes a frozen String of a few
  # hundred bytes by moving its bytes to a hidden String and pointing the fixture at that one
  # (InRactors.shareable says why that loses a fixture's bytes in Ractors). The write must find the
  # fixture already safe to read from, so its record shows no such move.
  def test_a_string_fixture_written_to_a_file_is_left_as_it_was
    holder = fixture_holder
    holder.const_set(:COPY, Array.new(512) { |at| at & 0xFF }.pack("C*").freeze)

    Dir.mktmpdir { |folder| File.binwrite(File.join(folder, "copy.bin"), holder::COPY) }

    refute moved_to_hidden_string?(holder::COPY), "the write moved the fixture's bytes"
    assert_equal Array.new(512) { |at| at & 0xFF }, holder::COPY.bytes
  end

  # The same for a module of shared fixtures, which shares its constants once they are all declared.
  def test_a_module_s_string_fixtures_are_left_as_they_were_by_a_write
    fixtures = Module.new
    fixtures.const_set(:COPY, Array.new(512) { |at| (at * 3) & 0xFF }.pack("C*").freeze)
    fixtures.const_set(:SIZES, [1, 2].freeze)
    VBlank::Testing::InRactors.share_constants(fixtures)

    Dir.mktmpdir { |folder| File.binwrite(File.join(folder, "copy.bin"), fixtures::COPY) }

    refute moved_to_hidden_string?(fixtures::COPY), "the write moved the fixture's bytes"
    assert Ractor.shareable?(fixtures::SIZES)
  end

  # Whether +string+'s bytes are another String's now, as ObjectSpace's record of it says.
  private def moved_to_hidden_string?(string) = JSON.parse(ObjectSpace.dump(string)).fetch("shared", false)

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
