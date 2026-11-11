# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

module VBlank
  module IR
    module Backends
      class Native
        # Turns C into a program the computer can run, with zig as the C compiler.
        #
        # zig carries clang and a C library of its own for every platform it targets, which is
        # why this backend uses it rather than whatever compiler the machine happens to have:
        # the same zig builds the same program on a Mac, on Linux, and for Windows from either.
        #
        # A compile is slow next to everything else a test does, so the result is kept and
        # handed back the next time the same C is asked for with the same settings. The key is
        # a hash of the sources, every file in every folder headers are found in, every flag,
        # and zig's own version, so a change to any of them builds again.
        module Zig
          # The zig this backend is written against. The SDL package the desktop build fetches
          # wants this one too, and zig changes enough between versions that "whatever is
          # installed" is not a promise anybody could keep.
          VERSION = "0.17."

          # What every compile is held to. The generated C is written to give no warnings at
          # all, so any warning is a mistake in the generator and stops the build. The two
          # conversion warnings are the ones that matter most: a number squeezed into something
          # smaller, or a signed number read as unsigned, without going through rg_int32.h.
          WARNINGS = Ractor.make_shareable(%w[-std=c11 -Wall -Wextra -Wconversion -Wsign-conversion -Werror])

          # How hard to optimise, and whether to check for undefined behaviour while it runs.
          #   :checked  no optimisation, every undefined-behaviour check on, and the first one
          #             found stops the program with the line it happened on. What tests use.
          #   :fast     optimised as hard as a release would be, with no checks. Tests run this
          #             too, because optimisation is what turns hidden undefined behaviour into
          #             a wrong answer.
          OPTIMISE = Ractor.make_shareable({
                                             checked: %w[-O0 -g -fsanitize=undefined -fno-sanitize-recover=all],
                                             fast: %w[-O2]
                                           })

          RUNTIME_DIR = Ractor.make_shareable(File.expand_path("runtime", __dir__))
          BUILD_FILE = Ractor.make_shareable(File.expand_path("build/build.zig", __dir__))

          module_function

          # Compiles +sources+ (C files on disk) into one program, with zig's C compiler alone and
          # no SDL — which needs no network and takes seconds, so it is what the tests build —
          # and gives back its path. +include+ is folders to find headers in; the runtime's own
          # folder is always one.
          def compile_without_sdl(sources, include: [], mode: :checked)
            refresh_checker_flags_in_checkout
            folders = [RUNTIME_DIR, *include]
            flags = WARNINGS + OPTIMISE.fetch(mode) + folders.flat_map { |dir| ["-I", dir] }
            # Named for what it is rather than "program", so a person watching what is running on
            # the machine can tell these apart from everything else there.
            exe = File.join(compiled_programs_dir, cache_key(sources, folders, flags), "vblank-headless")
            prune_compiled_programs
            if File.exist?(exe)
              FileUtils.touch(File.dirname(exe)) # Used now, so the next prune keeps it
              return exe
            end

            FileUtils.mkdir_p(File.dirname(exe))
            building = "#{exe}.#{Process.pid}.#{rand(1 << 30)}" # renamed into place once whole
            Dir.mktmpdir("vblank-zig-local") do |local|
              capture_command(compiler_cache_env(local), "zig", "cc", *flags, "-o", building, *sources)
            end
            File.rename(building, exe)
            exe
          end

          # WHERE ZIG KEEPS WHAT IT COMPILES. Left to itself, zig cc writes every object file into
          # ~/.cache/zig, which every zig project on the machine shares and nothing ever prunes, and
          # since every test writes new C every compile adds files nobody reads again. zig splits
          # what it keeps in two: the libraries every compile links (compiler_rt and the
          # undefined-behaviour checker), which take seconds to build and stay one size, and each
          # compile's own objects. So the libraries go in a folder of vblank's own, kept between
          # runs, and each compile's objects go in +local+, a folder that goes when it ends.
          # Must keep the global folder: without it every compile builds those libraries again.
          def compiler_cache_env(local)
            { "ZIG_GLOBAL_CACHE_DIR" => compiler_cache_dir, "ZIG_LOCAL_CACHE_DIR" => local }
          end

          # The libraries zig cc links into every program the tests build.
          def compiler_cache_dir = File.join(Dir.home, ".cache", "vblank", "zig-cc")

          # Builds +sources+ (C files in +src_dir+) and SDL3 into one program called +name+, with
          # zig's build system (build/build.zig), and gives back where it landed under +prefix+.
          # SDL is fetched and compiled into a cache kept between builds and shared by every
          # game, so only the first build pays for it. Raises, as #version does, on a zig this
          # was not written against. +target+ is another computer to build for, as zig names it
          # (see Native::TARGETS), and nil is this one. +strip+ leaves the debugging data out.
          def build_with_sdl(src_dir, sources, name:, prefix:, target: nil, strip: false)
            version
            # zig 0.17's build takes no --global-cache-dir; the setting is how it is told.
            capture_command({ "ZIG_GLOBAL_CACHE_DIR" => File.join(sdl_build_cache_dir, "global") },
                            "zig", "build", "--build-file", BUILD_FILE,
                            "--cache-dir", File.join(sdl_build_cache_dir, "cache"),
                            "--pkg-dir", File.join(sdl_build_cache_dir, "packages"),
                            "-p", prefix, "-Dsrc_dir=#{src_dir}", *sources.map { |file| "-Dsources=#{file}" },
                            "-Dname=#{name}", "-Doptimize=ReleaseFast", *(target ? ["-Dtarget=#{target}"] : []),
                            *(strip ? ["-Dstrip=true"] : []))
            windows = target ? target.include?("windows") : Gem.win_platform?
            File.join(prefix, "bin", windows ? "#{name}.exe" : name)
          ensure
            # After the build, which is what fetches SDL and its headers — and after one that
            # fetched them and then failed, too.
            refresh_checker_flags_in_checkout
          end

          # Where the desktop builds keep what zig compiled — SDL above all — between builds.
          def sdl_build_cache_dir = File.join(Dir.home, ".cache", "vblank", "native")

          # --- for an editor's C checker ---
          #
          # An editor that checks C as it is typed (clangd is the usual one) reads the runtime's
          # files on its own, knowing nothing of how they are built. With no flags it holds them
          # to none of the build's warnings, and with no folders to find headers in it reports
          # every name SDL declares as one nobody declared. It looks in a C file's folder, and
          # then each folder above it, for a compile_flags.txt, one flag to a line, and reads
          # the file with those.
          #
          # So the flags are written from here, from the same list a compile is handed (WARNINGS;
          # build/build.zig keeps a copy for the desktop build, which a test holds to it). The
          # file names folders on this machine, so it is written rather than checked
          # in — and NOBODY RUNS ANYTHING TO GET IT: every build looks at it and writes it again
          # when it is out of date (#refresh_checker_flags_in_checkout). A fresh checkout has it after its
          # first build, the build that fetches SDL adds SDL's folder to it, and a change to the
          # build's flags reaches it on the next build. It sits one folder above the runtime and
          # not in it, because every file in the runtime's folder is part of what a compile is
          # remembered by (#cache_key).
          #
          # WHAT THE FLAGS DO NOT CURE. A checker keeps its reading of a header between edits.
          # When a header changes and it has not caught up, it reads the file's new text at the
          # old positions and reports nonsense from the middle of a comment ("invalid suffix on
          # integer constant", on a line that only names a number the header defines). That
          # goes when it reads the header again, and it is not a fault in the code. To ask the
          # compiler itself:
          #
          #   rake test:lowering:native TEST=test/lowering/native/vblank/ir/backends/native/test_native_checker_flags.rb

          CHECKER_FLAGS_FILE = Ractor.make_shareable(File.expand_path("compile_flags.txt", __dir__))

          # ...and beside the C the native tests compile around one header (a harness), which the
          # checker reads from a folder with no flags above it otherwise. Written only where the
          # test folder is there, which is a checkout.
          HARNESS_CHECKER_FLAGS_FILE = Ractor.make_shareable(
            VBlank.root.join("test", "lowering", "native", "vblank", "ir", "backends", "native", "compile_flags.txt").to_s
          )

          # What the build holds the runtime to, and where its headers are found: its own folder,
          # and SDL's once a desktop build has fetched it.
          def checker_flags = WARNINGS + [RUNTIME_DIR, sdl_include_dir].compact.map { |dir| "-I#{dir}" }

          # Writes them to +path+ unless it already holds exactly them, and returns whether it
          # wrote. The file is put in place whole, so a checker never reads half of one; what is
          # being written meanwhile is named after the file, so git and the gem leave it out too.
          def refresh_checker_flags(path = CHECKER_FLAGS_FILE)
            wanted = checker_flags.map { |flag| "#{flag}\n" }.join
            return false if File.exist?(path) && File.read(path) == wanted

            writing = "#{path}.#{Process.pid}.#{rand(1 << 30)}"
            File.write(writing, wanted)
            File.rename(writing, path)
            true
          end

          # What every build does about that file: the same, where somebody is working on the
          # runtime's C, and nothing anywhere else. A folder that cannot be written is no reason
          # to stop a build.
          def refresh_checker_flags_in_checkout
            return unless working_in_checkout?

            refresh_checker_flags
            refresh_checker_flags(HARNESS_CHECKER_FLAGS_FILE) if File.directory?(File.dirname(HARNESS_CHECKER_FLAGS_FILE))
          rescue SystemCallError
            nil
          end

          # Whether the build was started from inside a git checkout of this library — which
          # is where its own tests and tools are run. A game that takes the library from git has
          # a checkout of it too, in bundler's folder, but is built from the game's own folder,
          # so that copy is not written into.
          def working_in_checkout?
            root = VBlank.root.to_s
            File.exist?(File.join(root, ".git")) && "#{Dir.pwd}/".start_with?("#{root}/")
          end

          # The folder the newest SDL fetched on this machine keeps its headers in, or nil before
          # the first desktop build. An older SDL left beside it is not named: headers from two
          # of them, with the old ones found first, is what a checker must not be given.
          def sdl_include_dir
            Dir.glob(File.join(sdl_build_cache_dir, "packages", "*", "include"))
               .select { |dir| File.exist?(File.join(dir, "SDL3", "SDL.h")) }
               .max_by { |dir| File.mtime(dir) }
          end

          # The installed zig's version, refusing one this backend was not written against.
          def version
            found = capture_command("zig", "version").strip
            return found if found.start_with?(VERSION)

            raise Computer::Error, "this needs zig #{VERSION}x, and the zig installed is #{found}. Pin it for this " \
                                  "project in mise (zig = \"0.17.0\") and run `mise install`."
          end

          def cache_key(sources, folders, flags)
            digest = Digest::SHA256.new
            digest << version << "\0" << flags.join("\0")
            files = sources + folders.flat_map { |dir| Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) } }
            files.uniq.sort.each { |path| digest << "\0" << path << "\0" << File.binread(path) }
            digest.hexdigest[0, 24]
          end

          # Where programs compiled without SDL are kept, by the hash of what made them.
          def compiled_programs_dir = File.join(Dir.tmpdir, "vblank-native")

          # How long a kept program stays after it was last built or used, and how often the
          # folder is looked over. Every test writes new C, so a day of runs builds programs by
          # the tens of thousands, and the system clears its temporary folder far too slowly to
          # keep up. A program a run still uses is touched each time, so it stays.
          KEEP_PROGRAM_SECONDS = 6 * 60 * 60
          PRUNE_EVERY_SECONDS = 60 * 60

          # Removes the kept programs nothing has built or used for KEEP_PROGRAM_SECONDS, at most
          # once every PRUNE_EVERY_SECONDS across every process (a stamp file holds the time). A
          # program another process removes first, or one it is writing, is no reason to stop.
          # The folders of C a game was written into are kept here too (Native#write_source), and
          # a build that uses one again touches it. Each folder is renamed before it is removed, so
          # a build looking for it finds a whole folder or none, never one with half its files gone.
          def prune_compiled_programs
            dir = compiled_programs_dir
            stamp = File.join(dir, ".pruned")
            return if File.exist?(stamp) && File.mtime(stamp) > Time.now - PRUNE_EVERY_SECONDS

            FileUtils.mkdir_p(dir)
            FileUtils.touch(stamp)
            cutoff = Time.now - KEEP_PROGRAM_SECONDS
            Dir.children(dir).each do |name|
              path = File.join(dir, name)
              next if path == stamp || File.mtime(path) >= cutoff

              removing = "#{path}.removing.#{Process.pid}"
              File.rename(path, removing)
              # A build may have touched it between the look and the rename: then it is put back.
              next File.rename(removing, path) if File.mtime(removing) >= cutoff

              FileUtils.rm_rf(removing)
            rescue SystemCallError
              next
            end
          end

          # Runs a command to the end, with +env+ added to its environment if the first argument is
          # a Hash, and gives back what it printed; a failure raises with what it printed to say why.
          def capture_command(*command)
            env = command.first.is_a?(Hash) ? command.shift : {}
            out, err, status = Open3.capture3(env, *command)
            return out if status.success?

            raise Computer::Error, "#{command.first(2).join(' ')} failed:\n#{err}#{out}"
          rescue Errno::ENOENT
            raise Computer::Error, "zig was not found. This project installs it through mise: run `mise install`."
          end

          private_class_method :cache_key, :compiled_programs_dir, :sdl_build_cache_dir, :capture_command,
                               :compiler_cache_env, :compiler_cache_dir, :prune_compiled_programs,
                               :refresh_checker_flags_in_checkout, :working_in_checkout?
        end
      end
    end
  end
end
