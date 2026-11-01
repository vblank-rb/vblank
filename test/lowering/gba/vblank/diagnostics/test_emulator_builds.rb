# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../../../../../ext/vblank/emulator_builds"

# What an install does when an emulator cannot be built: it carries on and leaves the reason behind
# for whoever wants that emulator. Whether a real install builds them is the release check's
# question (tools/gem_install_check), which has a machine to try it on.
class TestEmulatorBuilds < Minitest::Test
  def test_a_failed_build_leaves_its_reason_and_does_not_stop
    Dir.mktmpdir do |folder|
      EmulatorBuilds.attempt(folder, out: StringIO.new) { raise "a C compiler is not installed" }

      assert_includes File.read(File.join(folder, "NOT_BUILT")), "a C compiler is not installed"
    end
  end

  # What `gem pristine` relies on: building again after the fix clears the old reason.
  def test_a_build_that_works_clears_an_old_reason
    Dir.mktmpdir do |folder|
      File.write(File.join(folder, "NOT_BUILT"), "an old reason")
      EmulatorBuilds.attempt(folder, out: StringIO.new) { :built }

      refute_path_exists File.join(folder, "NOT_BUILT")
    end
  end

  # A game's bundle builds the same source as a gem of its own at the same moment, so an install
  # builds on a copy and leaves nothing in the folder the other build is using.
  def test_a_build_works_on_a_copy_of_the_source
    folder = VBlank.root.join("ruby-gba-emulator").to_s
    EmulatorBuilds.with_copy_of_source(folder) do |copy|
      refute copy.start_with?(folder)
      assert_path_exists File.join(copy, "extconf.rb")
      assert_path_exists File.join(copy, "..", "..", "lib", "ruby_gba_emulator", "built_from.rb")
    end
  end

  def test_an_install_without_the_emulator_says_why_and_not_what_a_checkout_does
    said = VBlank::Diagnostics::Emulator.send(:missing_advice, "cannot load such file -- ruby_gba_emulator",
                                              bundled: false, not_built: "libmgba not found")

    assert_includes said, "libmgba not found"
    assert_includes said, "gem pristine vblank"
    refute_includes said, "rake"
  end
end
