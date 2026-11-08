# frozen_string_literal: true

require "test_helper"

# WHAT A PERSON IS TOLD WHEN THE EMULATOR WILL NOT LOAD: each of the four cases, with the facts it
# turns on handed in, so none needs a machine where the emulator is missing in that way.
class TestMissingEmulator < Minitest::Test
  # THE ERROR SETTLES IT, NOT THE BUNDLE. A tool run as a plain `ruby` subprocess has no bundle
  # at all, so "is the gem in your bundle" answers no however the load really failed — and the
  # advice that follows tells somebody to add a Gemfile block they already have. What the loader
  # said is the thing that knows.
  def test_a_build_from_another_ruby_is_told_to_rebuild
    said = advice("linked to incompatible /rubies/4.0.5/lib/libruby.4.0.dylib - ext.bundle", bundled: false)

    assert_includes said, "rake compile_emulator"
    refute_includes said, "Gemfile", "the bundle is not what is wrong"
  end

  def test_a_library_the_loader_cannot_find_is_told_the_same
    said = advice("libruby.so.4.0: cannot open shared object file", bundled: false)

    assert_includes said, "rake compile_emulator"
    refute_includes said, "Gemfile"
  end

  # The two cases underneath. A `path:` entry resolves the gem and builds nothing, so that one is
  # told to build...
  def test_a_gem_in_the_bundle_with_nothing_built_is_told_to_build
    said = advice("cannot load such file -- ruby_gba_emulator/ruby_gba_emulator_ext", bundled: true)

    assert_includes said, "rake compile_emulator"
    refute_includes said, "Gemfile"
  end

  # ...and somebody with none of this installed is told how to get it, which is the usual case
  # and a reader building a game rather than repairing a checkout.
  def test_an_emulator_that_is_not_there_at_all_is_told_how_to_get_one
    said = advice("cannot load such file -- ruby_gba_emulator", bundled: false)

    assert_includes said, "Gemfile"
    refute_includes said, "different Ruby"
  end

  # An install that could not build the emulator left the reason beside it, and that comes first.
  def test_an_install_without_the_emulator_says_why_and_not_what_a_checkout_does
    said = advice("cannot load such file -- ruby_gba_emulator", bundled: false, not_built: "libmgba not found")

    assert_includes said, "libmgba not found"
    assert_includes said, "gem pristine vblank"
    refute_includes said, "rake"
  end

  private

  def advice(detail, bundled:, not_built: nil)
    VBlank::Diagnostics::MissingEmulator.new(detail: detail, bundled: bundled, not_built: not_built).advice
  end
end
