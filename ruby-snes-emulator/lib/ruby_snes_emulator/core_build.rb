# frozen_string_literal: true

require "etc"
require "fileutils"
require "open-uri"
require "open3"
require "tmpdir"

module RubySNESEmulator
  # MAKING THE CORE: bsnes, at the revision below, with core/bsnes-vblank-probe.patch, built as a
  # libretro core.
  #
  # Why bsnes, and why patched. bsnes is the most accurate Super Nintendo emulator there is, which
  # is what a check of a cartridge wants. Its libretro front end hands over no memory at all
  # (retro_get_memory_data gives nothing for every id), and snes9x's hands over work RAM and video
  # RAM but not the colour memory or the sprite table — so neither does, out of the box, what this
  # is for. The patch is small: a member of the accurate PPU that copies out its video RAM, colour
  # memory and sprite table (and the 65816's registers), and retro_get_memory_data handing those
  # over beside work RAM and the cartridge's RAM.
  #
  # It runs in two places: `rake compile_core` in a checkout, and `gem install vblank`, through
  # ext/vblank/Rakefile. So it takes nothing but the tools below, and no git, because the source is
  # one archive of one commit. By hand the steps are:
  #
  #   curl -L ARCHIVE | tar xz --strip-components=1
  #   patch -p1 -i ruby-snes-emulator/core/bsnes-vblank-probe.patch
  #   make -C bsnes target=libretro binary=library build=performance -j4
  #
  # bsnes's own licence is GPLv3. Its source is fetched from where bsnes publishes it, so none of it
  # is in this repository or the gem; the patch is the part that is.
  module CoreBuild
    REVISION = "78474e5d39f58872dc21aca18cf9eb583b147fe7"
    ARCHIVE = "https://codeload.github.com/bsnes-emu/bsnes/tar.gz/#{REVISION}".freeze
    PATCH = File.expand_path("../../core/bsnes-vblank-probe.patch", __dir__)

    # Why a core could not be made, in words for the person installing.
    class CannotBuild < StandardError; end

    module_function

    # The tools the build needs that this machine lacks, in words. bsnes picks its compiler by
    # platform, and picks clang++ on a Mac, so that is the one asked after there.
    def missing_tools(platform: RUBY_PLATFORM, on_path: method(:on_path?))
      compiler = platform.include?("darwin") ? "clang++" : "g++"
      tools = { "a C++ compiler (#{compiler})" => compiler, "make" => "make", "patch" => "patch", "tar" => "tar" }
      tools.reject { |_, tool| on_path.call(tool) }.keys
    end

    def on_path?(tool)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
    end

    # Makes the core and puts it at +target+, or raises CannotBuild saying why and leaves nothing
    # there. Each step that reaches outside Ruby is a parameter, so that what surrounds them can be
    # tested without a download and a compiler.
    def make(target, on_path: method(:on_path?), run: method(:run_step), download: method(:download_archive))
      missing = missing_tools(on_path: on_path)
      raise CannotBuild, "#{missing.join(', ')} not installed" unless missing.empty?

      Dir.mktmpdir("bsnes") do |dir|
        archive = File.join(dir, "bsnes.tar.gz")
        download.call(archive)
        run.call("tar", "xzf", archive, "-C", dir, "--strip-components=1")
        run.call("patch", "--quiet", "-d", dir, "-p1", "-i", PATCH)
        source = File.join(dir, "bsnes")
        run.call("make", "-C", source, "target=libretro", "binary=library", "build=performance",
                 "-j#{Etc.nprocessors}")
        move_into_place(library_in(source), target)
      end
    end

    # bsnes names the library for the platform: .so on Linux, .dylib on macOS. It is kept as .so
    # whatever it was built as, since dlopen reads the file and never its name.
    def library_in(source)
      built = Dir[File.join(source, "out", "bsnes_libretro.{so,dylib}")].first
      built || raise(CannotBuild, "bsnes built, but left no library in bsnes/out/")
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
      raise CannotBuild, "the bsnes source could not be downloaded from #{ARCHIVE} (#{e.message})"
    end

    def run_step(*command)
      output, status = Open3.capture2e(*command)
      return if status.success?

      raise CannotBuild, "`#{command.first}` stopped:\n#{output.lines.last(10).join}"
    end
  end
end
