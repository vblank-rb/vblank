# frozen_string_literal: true

require "etc"
require "fileutils"
require "open-uri"
require "open3"
require "tmpdir"

module RubyDOSEmulator
  # MAKING THE CORE: DOSBox Pure at the release below, with core/dosbox-vblank-probe.patch, built as a
  # libretro core. DOSBox Pure is DOSBox (the emulator DOS games are played in today) written as one
  # libretro core: it runs without a window, steps one frame at a time, and takes a DOSBox
  # configuration file as its "game", so a test says what machine it wants (a VGA card, an AdLib, a
  # Sound Blaster at the usual place, a fixed speed) and what to run.
  #
  # Why patched. Its libretro front end hands over no memory at all. A check of a DOS program wants
  # the first megabyte of the PC's memory, the video card's memory and palette, and the card's mode.
  # The patch is small: names for those in retro_get_memory_data.
  #
  # The release is the last one still published on GitHub: the author has moved the project to
  # Codeberg, where nothing here can reach it. The tag is named below rather than a branch for that
  # reason too.
  #
  # DOSBox Pure is GPL-2.0, so it is a tool for testing and is never shipped with VBlank's own code,
  # nor named in its gemspec. It needs no BIOS, no DOS and no disk image: it carries its own.
  #
  # The source is one archive of one tag, so the build takes nothing but the tools below, and no git.
  # By hand the steps are:
  #
  #   curl -L ARCHIVE | tar xz --strip-components=1
  #   patch -p1 -i ruby-dos-emulator/core/dosbox-vblank-probe.patch
  #   make -j4 CPUFLAGS=-Wl,--version-script=ruby-dos-emulator/core/dosbox-exports.map
  #
  # (on macOS, CPUFLAGS=-Wl,-exported_symbols_list,ruby-dos-emulator/core/dosbox-exports-macos.txt)
  #
  # VBLANK_DOS_CORE points the gem at a core built some other way.
  module CoreBuild
    REVISION = "1.0-preview6"
    ARCHIVE = "https://codeload.github.com/schellingb/dosbox-pure/tar.gz/#{REVISION}".freeze
    PATCH = File.expand_path("../../core/dosbox-vblank-probe.patch", __dir__)
    # The only symbols the core exports (see the file), which lets the system unload it again. GNU ld
    # reads a version script; the macOS linker has no such option and reads a list of symbol names
    # instead, each with the leading underscore its C names carry there.
    EXPORTS = File.expand_path("../../core/dosbox-exports.map", __dir__)
    EXPORTS_MACOS = File.expand_path("../../core/dosbox-exports-macos.txt", __dir__)

    # Why a core could not be made, in words for the person installing.
    class CannotBuild < StandardError; end

    module_function

    # The tools the build needs that this machine lacks, in words. The Makefile picks the platform's own
    # compiler, which is clang on a Mac.
    def missing_tools(platform: RUBY_PLATFORM, on_path: method(:on_path?))
      compiler = platform.include?("darwin") ? "clang++" : "g++"
      tools = { "a C++ compiler (#{compiler})" => compiler, "make" => "make", "patch" => "patch", "tar" => "tar" }
      tools.reject { |_, tool| on_path.call(tool) }.keys
    end

    def on_path?(tool)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
    end

    # Makes the core and puts it at +target+, or raises CannotBuild saying why and leaves nothing there.
    # Each step that reaches outside Ruby is a parameter, so that what surrounds them can be tested
    # without a download and a compiler.
    def make(target, on_path: method(:on_path?), run: method(:run_step), download: method(:download_archive))
      missing = missing_tools(on_path: on_path)
      raise CannotBuild, "#{missing.join(', ')} not installed" unless missing.empty?

      Dir.mktmpdir("dosbox-pure") do |dir|
        archive = File.join(dir, "dosbox-pure.tar.gz")
        download.call(archive)
        source = File.join(dir, "source")
        FileUtils.mkdir_p(source)
        run.call("tar", "xzf", archive, "-C", source, "--strip-components=1")
        run.call("patch", "--quiet", "-d", source, "-p1", "-i", PATCH)
        run.call("make", "-C", source, "-j#{Etc.nprocessors}", "CPUFLAGS=#{exports_linker_flag}")
        move_into_place(library_in(source), target)
      end
    end

    def exports_linker_flag(platform: RUBY_PLATFORM)
      return "-Wl,-exported_symbols_list,#{EXPORTS_MACOS}" if platform.include?("darwin")

      "-Wl,--version-script=#{EXPORTS}"
    end

    # The Makefile names the library for the platform: .so on Linux, .dylib on macOS. It is kept as the
    # name +target+ gives it whatever it was built as, since dlopen reads the file and never its name.
    def library_in(source)
      built = Dir[File.join(source, "dosbox_pure_libretro.{so,dylib}")].first
      built || raise(CannotBuild, "DOSBox Pure built, but left no dosbox_pure_libretro library to copy")
    end

    # Copied under another name and moved, so a build stopped half way leaves no part of a core.
    def move_into_place(built, target)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(built, "#{target}.new")
      File.rename("#{target}.new", target)
    end

    def download_archive(path)
      URI.parse(ARCHIVE).open { |remote| File.binwrite(path, remote.read) }
    rescue StandardError => e # no network shows up as many different errors, and all mean the same here
      raise CannotBuild, "the DOSBox Pure source could not be downloaded from #{ARCHIVE} (#{e.message})"
    end

    def run_step(*command)
      output, status = Open3.capture2e(*command)
      return if status.success?

      raise CannotBuild, "`#{command.first}` stopped:\n#{output.lines.last(10).join}"
    end
  end
end
