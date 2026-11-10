# frozen_string_literal: true

require_relative "test_helper"

# Copies of the core, one for each machine and never a second.
class TestCoreCopy < Minitest::Test
  CoreCopy = RubyDOSEmulator::CoreCopy

  def setup
    @folder = Dir.mktmpdir("core-copy-test")
    @library = File.join(@folder, "built.so")
    File.binwrite(@library, "the core")
  end

  def teardown = FileUtils.rm_rf(@folder)

  def test_a_copy_holds_the_library
    assert_equal "the core", File.binread(CoreCopy.make(@library, folder: @folder).path)
  end

  def test_two_copies_are_two_files
    first = CoreCopy.make(@library, folder: @folder)
    second = CoreCopy.make(@library, folder: @folder)

    refute_equal first.path, second.path
  end

  def test_a_deleted_copy_leaves_no_file
    copy = CoreCopy.make(@library, folder: @folder)
    copy.delete

    refute_path_exists copy.path
  end
end
