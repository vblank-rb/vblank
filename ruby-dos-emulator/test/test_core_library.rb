# frozen_string_literal: true

require "test_helper"
require "ruby_dos_emulator/core_library"

# What a person is told when there is no core to play a program in: a checkout is told how to build
# one, and an install that could not build one repeats why and the fix, which RubyGems never showed.
class TestCoreLibrary < Minitest::Test
  CoreLibrary = RubyDOSEmulator::CoreLibrary

  def test_an_install_that_could_not_build_the_core_repeats_why_and_the_fix
    message = CoreLibrary.missing_message(nil, not_built: "make is not installed\n")

    assert_includes message, "make is not installed"
    assert_includes message, "gem pristine vblank"
  end

  def test_a_checkout_with_no_core_is_told_to_build_one
    assert_includes CoreLibrary.missing_message(nil), "rake compile_core"
  end

  # The setting names a core somewhere else, so a reason left by the install is not the one that matters.
  def test_a_core_named_by_the_setting_and_missing_is_said_so_whatever_the_install_left
    message = CoreLibrary.missing_message("/nowhere/core.so", not_built: "make is not installed")

    assert_includes message, "/nowhere/core.so"
    refute_includes message, "gem pristine"
  end

  # The extension is required before the core is looked for, so an install that could not build either says
  # so there too.
  def test_an_install_that_could_not_build_the_extension_repeats_why_and_the_fix
    message = CoreLibrary.extension_missing_message("cannot load such file", not_built: "a C compiler (cc) is not installed\n")

    assert_includes message, "a C compiler (cc) is not installed"
    assert_includes message, "gem pristine vblank"
  end

  def test_a_checkout_with_no_extension_is_told_to_build_one
    assert_includes CoreLibrary.extension_missing_message("cannot load such file", not_built: nil), "rake compile"
  end
end
