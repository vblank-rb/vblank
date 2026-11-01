# frozen_string_literal: true

require "etc"
require "fileutils"
require "open-uri"
require "open3"
require "tmpdir"

module RubyGenesisEmulator
  # MAKING THE CORE: Genesis Plus GX, at the revision below, with core/gpgx-vblank-probe.patch, built as
  # a libretro core.
  #
  # Why Genesis Plus GX, and why patched. It is the most accurate Mega Drive emulator in common use
  # that is built as a libretro core, it runs without a window, steps one frame at a time and plays
  # the original cartridges VBlank's users own. Its libretro front end hands over work RAM and the
  # cartridge's save memory and nothing else, and a check of a cartridge wants the video RAM, the
  # colour memory and the scroll memory too. The patch is small: names for those memories (and for the
  # video chip's registers and the 68000's) in retro_get_memory_data.
  #
  # Its licence bars commercial use, which is why it is a tool for testing and is never shipped with
  # VBlank's own code, nor named in its gemspec. clownmdemu (AGPL) is the other emulator that was
  # weighed; this one met every need, so it was not used.
  #
  # The source is one archive of one commit, so the build takes nothing but the tools below, and no
  # git. By hand the steps are:
  #
  #   curl -L ARCHIVE | tar xz --strip-components=1
  #   patch -p1 -i ruby-genesis-emulator/core/gpgx-vblank-probe.patch
  #   make -f Makefile.libretro -j4
  #
  # VBLANK_GENESIS_CORE points the gem at a core built some other way.
  module CoreBuild
    REVISION = "f27655b592ef43f317272d79883bcaa10d3ac8ad"
    ARCHIVE = "https://codeload.github.com/libretro/Genesis-Plus-GX/tar.gz/#{REVISION}".freeze
    PATCH = File.expand_path("../../core/gpgx-vblank-probe.patch", __dir__)

    # Why a core could not be made, in words for the person installing.
    class CannotBuild < StandardError; end

    module_function

    # The tools the build needs that this machine lacks, in words. The Makefile picks the platform's own
    # compiler, which is clang on a Mac.
    def missing_tools(platform: RUBY_PLATFORM, on_path: method(:on_path?))
      compiler = platform.include?("darwin") ? "clang" : "gcc"
      tools = { "a C compiler (#{compiler})" => compiler, "make" => "make", "patch" => "patch", "tar" => "tar" }
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

      Dir.mktmpdir("gpgx") do |dir|
        archive = File.join(dir, "gpgx.tar.gz")
        download.call(archive)
        source = File.join(dir, "source")
        FileUtils.mkdir_p(source)
        run.call("tar", "xzf", archive, "-C", source, "--strip-components=1")
        run.call("patch", "--quiet", "-d", source, "-p1", "-i", PATCH)
        run.call("make", "-C", source, "-f", "Makefile.libretro", "-j#{Etc.nprocessors}")
        move_into_place(library_in(source), target)
      end
    end

    # The Makefile names the library for the platform: .so on Linux, .dylib on macOS. It is kept as the
    # name +target+ gives it whatever it was built as, since dlopen reads the file and never its name.
    def library_in(source)
      built = Dir[File.join(source, "genesis_plus_gx_libretro.{so,dylib}")].first
      built || raise(CannotBuild, "Genesis Plus GX built, but left no genesis_plus_gx_libretro library to copy")
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
      raise CannotBuild, "the Genesis Plus GX source could not be downloaded from #{ARCHIVE} (#{e.message})"
    end

    def run_step(*command)
      output, status = Open3.capture2e(*command)
      return if status.success?

      raise CannotBuild, "`#{command.first}` stopped:\n#{output.lines.last(10).join}"
    end
  end
end
