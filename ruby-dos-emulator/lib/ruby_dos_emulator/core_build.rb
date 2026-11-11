# frozen_string_literal: true

require "etc"
require "fileutils"
require "open-uri"
require "open3"
require "tmpdir"

module RubyDOSEmulator
  # MAKING THE CORE: DOSBox (the emulator DOS games are played in today) as libretro's dosbox-svn
  # core, at the commit below, with core/dosbox-vblank-probe.patch. As a libretro core it runs
  # without a window and takes a DOSBox configuration file as its "game", so a test says what
  # machine it wants (a VGA card, an AdLib, a Sound Blaster at the usual place, a fixed speed) and
  # what to run.
  #
  # Why this core. It emulates on the caller's own thread: the machine is a coroutine the frontend
  # switches into, and no thread is started. And it has a timing ("external", which the patch's
  # frontend asks for) in which the machine keeps no time by the host's clock and every retro_run
  # ends when the video card has finished one picture. So a frame is exactly one picture, the same
  # on every run, and nothing is running when Ruby reads the machine.
  #
  # Why patched. Its libretro front end hands over system memory and nothing else. A check of a DOS
  # program wants the video card's memory and palette and the card's mode too, and the frontend's
  # half has to be in C (the comment in the patch says why). The patch also makes the build work on
  # a Mac without SDL, and names what the library exports: libretro's functions and the probe's, and
  # nothing else. Without that last part the library exports a copy of every C++ standard-library
  # template it uses, the system's C++ library binds to those copies, and the system then never
  # unloads the core: each machine would leave its static memory behind for as long as the process lives.
  #
  # The core is GPL-2.0, so it is a tool for testing and is never shipped with VBlank's own code,
  # nor named in its gemspec. It needs no BIOS, no DOS and no disk image: it carries its own.
  #
  # The source is two archives, each of one commit: the core, and libretro-common (the core's git
  # submodule for it, at the commit the core pins), which has the coroutines. So the build takes
  # nothing but the tools below, and no git. By hand the steps are:
  #
  #   curl -L ARCHIVE | tar xz --strip-components=1
  #   curl -L COMMON_ARCHIVE | tar xz --strip-components=1 -C libretro/deps/common
  #   patch -p1 -i ruby-dos-emulator/core/dosbox-vblank-probe.patch
  #   make -C libretro -f Makefile.libretro WITH_FAKE_SDL=1 WITH_IPX=0 WITH_DYNAREC=
  #
  # The three settings: no SDL (the core's own stand-in for the little of it DOSBox needs), no
  # network card, and no translator of 386 code into the host's (the plain interpreter is the same
  # on every machine).
  #
  # Built and tested on macOS. The Linux build takes the same steps and has not been run.
  #
  # VBLANK_DOS_CORE points the gem at a core built some other way.
  module CoreBuild
    REVISION = "46a3164fc0f1e808ae56143d81698b00fb6b4781"
    ARCHIVE = "https://codeload.github.com/libretro/dosbox-svn/tar.gz/#{REVISION}".freeze
    COMMON_REVISION = "fa8a1b572a444fcb552007019f8caf68281108aa"
    COMMON_ARCHIVE = "https://codeload.github.com/libretro/libretro-common/tar.gz/#{COMMON_REVISION}".freeze
    PATCH = File.expand_path("../../core/dosbox-vblank-probe.patch", __dir__)
    MAKE_SETTINGS = %w[WITH_FAKE_SDL=1 WITH_IPX=0 WITH_DYNAREC=].freeze

    # Why a core could not be made, in words for the person installing.
    class CannotBuild < StandardError; end

    module_function

    # The tools the build needs that this machine lacks, in words. The Makefile calls the compilers
    # by the names every system gives its own (c++ and cc), which are clang on a Mac.
    def missing_tools(platform: RUBY_PLATFORM, on_path: ->(tool) { on_path?(tool) })
      compiler = platform.include?("darwin") ? "clang++" : "g++"
      tools = { "a C++ compiler (#{compiler})" => "c++", "make" => "make", "patch" => "patch", "tar" => "tar" }
      tools.reject { |_, tool| on_path.call(tool) }.keys
    end

    def on_path?(tool)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, tool)) }
    end

    # Makes the core and puts it at +target+, or raises CannotBuild saying why and leaves nothing there.
    # Each step that reaches outside Ruby is a parameter, so that what surrounds them can be tested
    # without a download and a compiler.
    def make(target, on_path: ->(tool) { on_path?(tool) }, run: ->(*command) { run_step(*command) },
             download: ->(url, path) { download_archive(url, path) })
      missing = missing_tools(on_path: on_path)
      raise CannotBuild, "#{missing.join(', ')} not installed" unless missing.empty?

      Dir.mktmpdir("dosbox-svn") do |dir|
        source = File.join(dir, "source")
        unpack(ARCHIVE, source, dir, run: run, download: download)
        unpack(COMMON_ARCHIVE, File.join(source, "libretro", "deps", "common"), dir, run: run, download: download)
        run.call("patch", "--quiet", "-d", source, "-p1", "-i", PATCH)
        run.call("make", "-C", File.join(source, "libretro"), "-f", "Makefile.libretro", "-j#{Etc.nprocessors}", *MAKE_SETTINGS)
        move_into_place(library_in(File.join(source, "libretro")), target)
      end
    end

    # Downloads the archive at +url+ and unpacks what its one top folder holds into +folder+.
    def unpack(url, folder, dir, run:, download:)
      archive = File.join(dir, "archive.tar.gz")
      download.call(url, archive)
      FileUtils.mkdir_p(folder)
      run.call("tar", "xzf", archive, "-C", folder, "--strip-components=1")
    end

    # The Makefile names the library for the platform: .so on Linux, .dylib on macOS. It is kept as the
    # name +target+ gives it whatever it was built as, since dlopen reads the file and never its name.
    def library_in(folder)
      built = Dir[File.join(folder, "dosbox_svn_libretro.{so,dylib}")].first
      built || raise(CannotBuild, "DOSBox built, but left no dosbox_svn_libretro library to copy")
    end

    # Copied under another name and moved, so a build stopped half way leaves no part of a core.
    def move_into_place(built, target)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(built, "#{target}.new")
      File.rename("#{target}.new", target)
    end

    def download_archive(url, path)
      URI.parse(url).open { |remote| File.binwrite(path, remote.read) }
    rescue StandardError => e # no network shows up as many different errors, and all mean the same here
      raise CannotBuild, "the DOSBox source could not be downloaded from #{url} (#{e.message})"
    end

    def run_step(*command)
      output, status = Open3.capture2e(*command)
      return if status.success?

      raise CannotBuild, "`#{command.first}` stopped:\n#{output.lines.last(10).join}"
    end
  end
end
