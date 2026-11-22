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

  # A fixture string written to a file is left as it was. Ruby writes a frozen String of a few
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

  # A constant this suite's files declare outside a test class, in a module of fixtures several
  # files share say, is frozen as it is declared too: test_helper asks for every file under test/.
  def test_a_constant_a_test_file_declares_in_a_module_is_frozen_as_declared
    fixtures = Module.new
    fixtures.const_set(:ITEMS, { byte: [1, 200] })

    assert Ractor.shareable?(fixtures::ITEMS)
  end

  # A file elsewhere, the library's or a gem's, keeps its constants as it wrote them.
  def test_a_constant_declared_outside_the_folder_is_left_alone
    holder = Module.new
    holder.module_eval("ITEMS = [+'red']", "/elsewhere/fixtures.rb", 1)

    refute Ractor.shareable?(holder::ITEMS)
  end

  # A String INSIDE a fixture (an Array, a Hash, a Data) is safe to write too: six Ractors writing
  # each one at once leave every fixture whole, and no write moves its bytes.
  Pages = Data.define(:copy)

  def test_strings_inside_a_fixture_stay_whole_written_from_six_ractors
    bytes = Array.new(512) { |at| (at * 7) & 0xFF }
    fixtures = Module.new
    fixtures.const_set(:LISTED, [bytes.pack("C*")].freeze)
    fixtures.const_set(:KEYED, { copy: bytes.pack("C*") }.freeze)
    fixtures.const_set(:PAGES, Pages.new(copy: bytes.pack("C*")))
    VBlank::Testing::InRactors.share_constants(fixtures)
    nested = [fixtures::LISTED.first, fixtures::KEYED.fetch(:copy), fixtures::PAGES.copy]

    Dir.mktmpdir do |folder|
      writers = Array.new(6) do |nth|
        Ractor.new(nested, folder, nth) do |strings, into, at|
          strings.each_with_index { |string, which| File.binwrite(File.join(into, "#{at}-#{which}.bin"), string) }
        end
      end
      writers.each(&:value)
    end

    nested.each_with_index do |string, which|
      refute moved_to_hidden_string?(string), "the write moved fixture #{which}'s bytes"
      assert_equal bytes, string.bytes, "fixture #{which}"
    end
  end

  # Whether +string+'s bytes are another String's now, as ObjectSpace's record of it says.
  private def moved_to_hidden_string?(string) = JSON.parse(ObjectSpace.dump(string)).fetch("shared", false)

  # A failing comparison of two long binary strings in a Ractor shows its diff. Minitest looks for
  # a diff program the first time one is needed, reading RbConfig::CONFIG, which a Ractor may not
  # read: the failure became a Ractor::IsolationError that hid what differed.
  def test_a_failing_binary_comparison_in_a_ractor_shows_its_diff
    message = Ractor.new do
      expected = Array.new(200) { |at| at & 0xFF }.pack("C*")
      actual = expected.dup
      actual.setbyte(100, 7)
      begin
        TestInRactors.new("test_this_suite_plays_with_it").assert_equal(expected, actual)
        "the comparison passed"
      rescue Minitest::Assertion, Ractor::IsolationError => e
        "#{e.class}: #{e.message}"
      end
    end.value

    assert_match(/^Minitest::Assertion: --- expected\n\+\+\+ actual\n/, message)
    refute_match(/IsolationError/, message)
  end

  # A test written in a loop is a method made from a block. On a run in Ractors it is made from a
  # shareable copy, which a worker can call; on any other run it is the block as written.
  def test_a_method_a_test_class_makes_from_a_block_is_shareable_on_a_run_in_ractors_alone
    tests = Class.new(Minitest::Test)
    { small: 4, large: 9 }.each { |size, most| tests.define_method(:"bound_#{size}") { most } }
    in_a_worker = Ractor.new(tests) do |made|
      made.new("bound_large").bound_large
    rescue RuntimeError
      :refused
    end.value

    assert_equal 9, tests.new("bound_large").bound_large
    assert_equal VBlank::Testing::InRactors::RACTOR_RUN ? 9 : :refused, in_a_worker
  end

  # The copy is the block with what it reads from around it fixed; one that reads a value that can
  # change cannot be copied and stays as it was, for the Ractor run to name.
  def test_a_block_reading_a_value_that_can_change_is_left_as_it_was
    seen = [+"red"]
    block = -> { seen }

    assert_same block, VBlank::Testing::InRactors.shareable_block(block)
    assert Ractor.shareable?(VBlank::Testing::InRactors.shareable_block(-> { 9 }))
  end

  # define_method stays public, as Module's own is.
  def test_define_method_stays_public_on_a_test_class
    assert_includes Class.new(Minitest::Test).public_methods, :define_method
  end

  # A module of tests a test file declares makes its loop-made tests as a test class does.
  def test_a_module_of_tests_declared_here_makes_its_methods_as_a_test_class_does
    self.class.const_set(:SharedLoopTests, Module.new)

    assert_kind_of VBlank::Testing::InRactors::ShareableMethods, self.class::SharedLoopTests
  ensure
    self.class.module_exec { remove_const(:SharedLoopTests) if const_defined?(:SharedLoopTests, false) }
  end

  # A value that cannot be shared, one holding a Mutex, is left as it was and the file goes on
  # loading: a test that reads it in a Ractor is refused, naming it.
  def test_a_constant_holding_a_mutex_is_left_unfrozen
    holder = Module.new
    holder.const_set(:LOCK, [Mutex.new])

    refute Ractor.shareable?(holder::LOCK)
  end

  # A constant is frozen in place where it can be, and set again at its own line where its Strings
  # are interned, so Ruby still says the file and line that declared it.
  def test_a_shared_constant_keeps_the_place_that_declared_it
    holder = Module.new
    line = __LINE__ + 1
    holder.module_eval("NUMBERS = [1, 2]\nWORDS = [+'red']", __FILE__, line)

    assert_equal [__FILE__, line], holder.const_source_location(:NUMBERS)
    assert_equal [__FILE__, line + 1], holder.const_source_location(:WORDS)
    assert Ractor.shareable?(holder::WORDS)
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
