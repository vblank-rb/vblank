# frozen_string_literal: true

require_relative "test_helper"

# Copies of the core kept to be opened again, one console at a time.
class TestKeptCopy < Minitest::Test
  KeptCopy = RubyPS1Emulator::KeptCopy

  def setup
    @folder = Dir.mktmpdir("kept-copy-test")
    @library = File.join(@folder, "built.so")
    File.binwrite(@library, "the core")
    @kept = File.join(@folder, "kept")
  end

  def teardown = FileUtils.rm_rf(@folder)

  private def take = KeptCopy.take(@library, folder: @kept)

  def test_a_copy_holds_the_library
    assert_equal "the core", File.binread(take.path)
  end

  def test_two_at_once_are_two_files
    first = take
    second = take

    refute_equal first.path, second.path
  end

  def test_a_copy_given_back_is_the_one_handed_out_next
    first = take
    path = first.path
    first.give_back

    assert_equal path, take.path
  end

  def test_a_new_build_of_the_core_gets_a_folder_of_its_own
    before = KeptCopy.folder_for(@library)
    File.binwrite(@library, "a bigger core")

    refute_equal before, KeptCopy.folder_for(@library)
  end
end
