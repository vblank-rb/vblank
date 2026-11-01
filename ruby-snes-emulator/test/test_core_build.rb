# frozen_string_literal: true

require "test_helper"
require "ruby_snes_emulator/core_build"

# How the core is made, without making one: that takes a download and a compiler, and the release
# check (tools/gem_install_check) does it for real. These hold the parts a real build would only
# show when something went wrong.
class TestCoreBuild < Minitest::Test
  CoreBuild = RubySNESEmulator::CoreBuild

  def test_every_tool_the_build_needs_is_named_when_it_is_missing
    assert_equal ["a C++ compiler (g++)", "make", "patch", "tar"], CoreBuild.missing_tools(platform: "linux", on_path: ->(_) { false })
  end

  def test_nothing_is_missing_when_every_tool_is_there
    assert_empty CoreBuild.missing_tools(platform: "linux", on_path: ->(_) { true })
  end

  def test_a_mac_is_asked_for_the_compiler_bsnes_uses_there
    missing = CoreBuild.missing_tools(platform: "darwin", on_path: ->(tool) { tool != "clang++" })

    assert_equal ["a C++ compiler (clang++)"], missing
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

  # A build stopped part way leaves nothing a later run takes for a finished core.
  def test_a_build_that_fails_leaves_no_core
    Dir.mktmpdir do |dir|
      target = File.join(dir, "build", "core.so")
      failing = ->(*) { raise CoreBuild::CannotBuild, "the compiler stopped" }

      assert_raises(CoreBuild::CannotBuild) do
        CoreBuild.make(target, on_path: ->(_) { true }, run: failing, download: ->(_) {})
      end
      refute_path_exists target
    end
  end

  def test_the_finished_library_is_moved_to_where_it_was_asked_for
    Dir.mktmpdir do |dir|
      target = File.join(dir, "build", "core.so")
      compile = lambda do |*step|
        next unless step.first == "make"

        out = File.join(step[2], "out")
        FileUtils.mkdir_p(out)
        File.write(File.join(out, "bsnes_libretro.dylib"), "a library")
      end

      CoreBuild.make(target, on_path: ->(_) { true }, run: compile, download: ->(_) {})
      assert_equal "a library", File.read(target)
    end
  end

  def test_a_core_that_was_not_built_at_install_says_why
    said = RubySNESEmulator::CoreLibrary.missing_message(nil, not_built: "a C++ compiler (g++) is not installed")

    assert_includes said, "a C++ compiler (g++) is not installed"
    assert_includes said, "gem pristine vblank"
    refute_includes said, "rake"
  end
end
