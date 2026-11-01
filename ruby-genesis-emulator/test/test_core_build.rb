# frozen_string_literal: true

require "test_helper"
require "ruby_genesis_emulator/core_build"

# How the core is made, without making one: that takes a download and a compiler. These hold the parts a
# real build would only show when something went wrong, and the one a Mac needs: the library comes out of
# the build as a .dylib there.
class TestCoreBuild < Minitest::Test
  CoreBuild = RubyGenesisEmulator::CoreBuild

  def test_every_tool_the_build_needs_is_named_when_it_is_missing
    assert_equal ["a C compiler (gcc)", "make", "patch", "tar"], CoreBuild.missing_tools(platform: "linux", on_path: ->(_) { false })
  end

  def test_a_mac_is_asked_for_clang
    assert_equal ["a C compiler (clang)"], CoreBuild.missing_tools(platform: "darwin", on_path: ->(tool) { tool != "clang" })
  end

  def test_a_build_with_a_tool_missing_stops_before_it_downloads_anything
    Dir.mktmpdir do |dir|
      asked = []
      error = assert_raises(CoreBuild::CannotBuild) do
        CoreBuild.make(File.join(dir, "core.so"), on_path: ->(_) { false }, run: ->(*step) { asked << step })
      end

      assert_includes error.message, "make"
      assert_empty asked
    end
  end

  def test_a_build_that_fails_leaves_no_core
    Dir.mktmpdir do |dir|
      target = File.join(dir, "build", "core.so")
      failing = ->(*) { raise CoreBuild::CannotBuild, "the compiler stopped" }

      assert_raises(CoreBuild::CannotBuild) { CoreBuild.make(target, on_path: ->(_) { true }, run: failing, download: ->(_) {}) }
      refute_path_exists target
    end
  end

  def test_the_library_a_mac_builds_is_found_and_kept_under_the_name_asked_for
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "genesis_plus_gx_libretro.dylib"), "core")
      target = File.join(dir, "out", "genesis_plus_gx_libretro.so")

      CoreBuild.move_into_place(CoreBuild.library_in(dir), target)

      assert_equal "core", File.binread(target)
    end
  end

  def test_a_build_that_leaves_no_library_says_so
    Dir.mktmpdir do |dir|
      error = assert_raises(CoreBuild::CannotBuild) { CoreBuild.library_in(dir) }

      assert_includes error.message, "left no genesis_plus_gx_libretro library"
    end
  end
end
