# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "native/zig"
require_relative "native/names"
require_relative "native/start_file_numbers"
require_relative "native/console_numbers"
require_relative "native/cartridge_start"
require_relative "native/c"
require_relative "native/printer"
require_relative "native/drawn_sprites"
require_relative "native/picture"
require_relative "native/sound_log"
require_relative "native/sound"
require_relative "native/saving"
require_relative "native/start_file_fills"
require_relative "native/lowering"
require_relative "native/headless_run"
require_relative "native/rules_run" # ...and a game's rules alone, read only as asked
require_relative "native/differences"
require_relative "native/checked_run"
require_relative "native/menu_data"
require_relative "native/shell_data"

module VBlank
  module IR
    module Backends
      # The game as a program for a desktop computer: the IR written out as C, built by zig into
      # one executable. The cartridge stays the main thing this library makes; this is a second
      # one beside it.
      #
      # It stands beside the other two backends: `rake test` plays every game in the suite as C
      # too (`rake test:lowering:native` plays only that), checked against the interpreter on
      # every frame, so a feature is not done until it works here as well.
      #
      # How it writes C, and why that way (doc/research/writing-c.md has the reading behind it):
      #
      # - The game's arithmetic lives in runtime/rg_int32.h, a C function for each thing
      #   IR::Int32 and the interpreter do with a number. C leaves several of the things a game
      #   does with numbers undefined — running off the end of a number, dividing the lowest
      #   number by -1, shifting by 32 — and an optimising compiler is allowed to assume they
      #   never happen. Those functions work on the unsigned kind of number, which C does
      #   promise wraps, and test the rest.
      # - The C this writes never uses an operator on one of the game's numbers; it calls one
      #   of those functions. That is what keeps it correct, and it is also why the precedence
      #   of C's operators, and && skipping its right side, never come up.
      # - It never names SDL, nor a file. The picture, the buttons, the sound and the save memory
      #   go through the runtime (runtime/rg_runtime.h and the headers beside it), which a
      #   desktop build links against SDL and a test links against a version that has no window
      #   at all.
      # - It is checked by running, against Backends::Reference, and never by comparing the C
      #   it wrote against C somebody wrote down.
      class Native
        # A game's program, checked the way a cartridge build checks it, every guardrail on, with no
        # cartridge made (Cartridge::Game#checked_program). So nothing the console's answers refuse
        # can be built for a desktop instead. What only the console's own code generator refuses (a
        # cartridge too full, a part it does not make yet) is found by building the cartridge, which
        # costs a big game most of a minute, so a computer's build leaves it to the cartridge build.
        # Guardrail warnings are printed to +err+, as the cartridge build prints them.
        #
        # The program is for +console+, one the game names, and the first it names when that is left
        # out. It is built as that console: the runtime's screen is its size (ConsoleNumbers), and the
        # program does what the game does on it. +pack_at_start+ leaves the game's data pack out
        # (Cartridge::Options).
        def checked_program(game, console: nil, settings: {}, err: $stderr, progress: Messages::Progress.silent,
                            pack_at_start: false)
          game.checked_program(err: err, progress: progress, settings: settings, console: console || game.consoles.first,
                               pack_at_start: pack_at_start)
        end

        # The cartridge a desktop build that plays the console's start-up reads the start of
        # (CartridgeStart), and whose checked program it is built from.
        def checked_cartridge(game, console: nil, settings: {}, err: $stderr, progress: Messages::Progress.silent)
          game.build_rom(profile: false, out: nil, err: err, settings: settings, progress: progress,
                         console: console || game.consoles.first, for_computer: true)
        end

        # The runtime's C files each kind of build compiles beside the game's. The desktop build
        # carries the windowless runtime too, so the program a player runs can be driven by a
        # test with --headless. It also carries the window's own settings (rg_window.c, plain C
        # with no SDL, tested on its own), the menu over the picture (rg_window_menu.c and its
        # letters, rg_menu_font.c, with what the menu holds written out by MenuData), the emulator
        # the console's own start-up runs in where the player has the BIOS (rg_bios_boot.c, with the
        # start of the game's cartridge beside it, CartridgeStart), and the windows of keys and of
        # the game's variables (rg_menu.cpp, Dear ImGui), which
        # build/build.zig compiles itself since it is C++ and wants flags of its own: a desktop
        # build always has them, and the builds a test makes of the game do not come through here
        # at all.
        SHARED_RUNTIME = %w[rg_headless.c rg_refusal.c rg_runtime.c rg_save.c rg_screen.c rg_sound.c].freeze
        HEADLESS_RUNTIME = (["rg_headless_main.c"] + SHARED_RUNTIME).freeze
        FEATURES_FILE = "rg_runtime_features.h" # What rg_screen.c includes for the game's features (RuntimeFeatures#c_text)
        SOUND_FEATURES_FILE = "rg_sound_features.h" # ...and rg_sound.c, for the game's sound features
        DESKTOP_RUNTIME = (%w[rg_sdl.c rg_window.c rg_window_menu.c rg_menu_font.c rg_bios_boot.c rg_shell.c] + [MenuData::FILE, ShellData::FILE] +
                           SHARED_RUNTIME).freeze

        # The program written out as C, as one file's text. A program from a game should come
        # through #checked_program first. +title+ is the game's name, for the window.
        def lower(program, title: "VBlank")
          Lowering.new(program, title: title).source
        end

        # The program built into a program with no window (runtime/rg_headless.c), and the
        # path to it. See that file for how it is run and what it prints. Built with zig on
        # its own, with no SDL to fetch or compile, which is what keeps the tests quick.
        def build_headless(program, mode: :checked)
          lowering = Lowering.new(program, title: "VBlank")
          game = write_source(lowering.source_files, ConsoleNumbers.header(program.described_console), lowering.runtime_features)
          Zig.compile_without_sdl([game, *HEADLESS_RUNTIME.map { |file| File.join(Zig::RUNTIME_DIR, file) }],
                                  include: [File.dirname(game), RuntimeFeatures::ROOT], mode: mode)
        end

        # THE OTHER COMPUTERS A GAME CAN BE BUILT FOR FROM THIS ONE, by the name a build asks for
        # each, and what zig calls it. zig carries the C library of each and SDL is compiled for
        # each from its own source, so nothing for them has to be installed here. Linux is held to
        # a C library from 2018, so the program also starts on an older system. A Mac cannot be
        # built for from anywhere else (Apple's licence keeps its SDK to Macs), so it is not here;
        # on a Mac, leaving the target out builds for the Mac.
        TARGETS = Ractor.make_shareable({ windows: "x86_64-windows-gnu", linux: "x86_64-linux-gnu.2.28",
                                          linux_arm: "aarch64-linux-gnu.2.28" })

        # +game+ built into ONE program with a window, written to +path+: the game checked as a
        # cartridge build checks it, written as C, and compiled with SDL3 by zig into an
        # executable that needs nothing installed beside it. The first build fetches SDL's source
        # and compiles it, which takes a while once; every build after that reuses it. +target+
        # names another computer to build for (see TARGETS), and left out it is this one. +console+
        # is the one it plays the game as (#checked_program). +strip+ leaves the program's debugging
        # data out: a far smaller file, and far poorer crash reports. +progress+ (a Messages::Progress)
        # is told each step as it begins: the build's, then writing the C and compiling it.
        #
        # +bios+ makes a program that uses the player's own BIOS for the console where it finds one:
        # today, to play the console's start-up before the game (runtime/rg_bios_boot.h). The BIOS
        # reads the start of the game's cartridge, so the cartridge is built too (CartridgeStart), which
        # is most of a big game's build; left out, the program never looks for a BIOS, starts the game
        # at once, and no cartridge is made.
        def build_desktop(game, path, console: nil, settings: {}, target: nil, strip: false, pack_at_start: false, bios: false,
                          err: $stderr, progress: Messages::Progress.silent)
          if File.directory?(path)
            raise LoweringError, "#{path} is a folder, so the program cannot be written there. Name a file instead."
          end
          refuse_unknown_target!(target)
          console ||= game.consoles.first
          refuse_unusable_bios!(console, pack_at_start) if bios

          cartridge = (checked_cartridge(game, console: console, settings: settings, err: err, progress: progress) if bios)
          program = cartridge&.source_program ||
                    checked_program(game, console: console, settings: settings, err: err, progress: progress, pack_at_start: pack_at_start)
          compile_desktop(program, path, title: game.title, menu: game.menu?, cartridge: cartridge, target: target, strip: strip,
                                         progress: progress)
          FileUtils.chmod(0o755, path)
          path
        ensure
          progress.done
        end

        # +game+ built as a SHELL (Original::Shell) for a computer, into the FOLDER +path+: the game, with
        # none of the original's data in it, named for the folder, and under parts/ the menu and one
        # unpacking for each release of the original the game reads, each a whole desktop program of its
        # own (runtime/rg_shell.h has why). Run the game: with no data pack kept in its folder among the
        # computer's files for the program, the menu plays; LOAD ROM opens the system's file dialog, the
        # copy is checked and unpacked, and the pack is kept and the game starts.
        #
        # The programs have no cartridge to read the console's start-up from, so a shell for the Advance
        # starts without it.
        def build_desktop_shell(game, path, console: nil, settings: {}, target: nil, strip: false, err: $stderr,
                                progress: Messages::Progress.silent)
          refuse_unknown_target!(target)
          if File.file?(path)
            raise LoweringError, "#{path} is a file, and a shell is a folder of programs. Name a folder instead."
          end

          shell = Original::Shell.build(game, console: console || game.consoles.first, settings: settings, err: err, progress: progress)
          FileUtils.mkdir_p(File.join(path, ShellData::PARTS_FOLDER))
          ending = target == :windows || (target.nil? && Gem.win_platform?) ? ".exe" : ""
          shell.parts.each do |part|
            game_part = part.role == :game
            file = game_part ? File.join(path, File.basename(path)) : File.join(path, ShellData::PARTS_FOLDER, ShellData.part_name(part))
            compile_desktop(part.program, "#{file}#{ending}", title: game.title, menu: part.window_menu, cartridge: nil, target: target,
                                                               strip: strip, shell: (shell if game_part), progress: progress,
                                                               part_name: game_part ? "game" : ShellData.part_name(part))
            FileUtils.chmod(0o755, "#{file}#{ending}")
          end
          path
        ensure
          progress.done
        end

        # A BIOS is used only for a console the program can run one for, and it reads the start of the
        # game's cartridge (CartridgeStart), which a build that leaves its data pack out does not make.
        def refuse_unusable_bios!(console, pack_at_start)
          described = Console.described(console)
          unless described.plays_bios_start_up
            raise LoweringError, "VBlank cannot use a #{described.title} BIOS yet. To build this program, leave out --bios."
          end
          return unless pack_at_start

          raise LoweringError, "The BIOS reads the game's cartridge, and a build that leaves its data pack out makes no " \
                               "cartridge. To build this program, leave out --bios or --pack-at-start."
        end

        def refuse_unknown_target!(target)
          return if target.nil? || TARGETS.key?(target)

          raise LoweringError, "There is no build for #{target.inspect}. A game can be built for " \
                               "#{TARGETS.keys.join(', ')}, or for this computer with no target."
        end

        private

        # +program+ compiled with the runtime and SDL into the executable +path+. The console's
        # start-up is played only where +cartridge+ holds the start of the game's cartridge to read it
        # from. +shell+ (an Original::Shell) makes the program a shell's game. +progress+ is told the two
        # steps, each with +part_name+ beside it where a shell builds several programs.
        def compile_desktop(program, path, title:, menu:, cartridge:, target:, strip:, shell: nil,
                            progress: Messages::Progress.silent, part_name: nil)
          progress.step("Writing C")
          progress.show_detail(part_name) if part_name
          lowering = Lowering.new(program, title: title)
          files = lowering.source_files
          Dir.mktmpdir("vblank-native") do |dir|
            src = File.join(dir, "src")
            FileUtils.mkdir_p(src)
            files.each { |name, body| File.binwrite(File.join(src, name), body) }
            # Each feature's folder beside the runtime, where game.c and rg_screen.c include it from.
            lowering.runtime_features.each { |feature| FileUtils.cp_r(feature.folder, src) }
            File.write(File.join(src, FEATURES_FILE), RuntimeFeatures.c_text(lowering.runtime_features))
            File.write(File.join(src, SOUND_FEATURES_FILE), RuntimeFeatures.c_text(lowering.runtime_features, joins: :sound))
            File.write(File.join(src, ConsoleNumbers::FILE), ConsoleNumbers.header(program.described_console, start_up: !cartridge.nil?))
            if cartridge && program.described_console.plays_bios_start_up
              File.write(File.join(src, CartridgeStart::FILE), CartridgeStart.header(cartridge.buffer))
            end
            File.write(File.join(src, MenuData::FILE), MenuData.source(menu: menu))
            File.write(File.join(src, ShellData::FILE), Printer.new.print_file(ShellData.items(shell)))
            Dir.glob(File.join(Zig::RUNTIME_DIR, "*")).each { |file| FileUtils.cp(file, src) }
            progress.step("Compiling C")
            progress.show_detail(part_name) if part_name
            exe = Zig.build_with_sdl(src, ["game.c", *DESKTOP_RUNTIME], name: "game", prefix: File.join(dir, "out"),
                                                                        target: target && TARGETS.fetch(target), strip: strip)
            FileUtils.cp(exe, path)
          end
        end

        # The C on disk, where the compiler can read it, with the console's numbers beside it
        # (ConsoleNumbers), in a folder named for what it holds so two programs never write over
        # each other. Each file is written under a name of its own and then renamed into place,
        # so two threads building the same game at once — tests run side by side — each put down a
        # whole file and never read half of the other's. +files+ are Lowering#source_files: game.c and
        # the files its big tables are embedded from, whose names are their fingerprints, so the text
        # alone names the folder. Gives back the path of game.c.
        def write_source(files, numbers, features)
          text = files.fetch(Lowering::GAME_FILE)
          screen_text = RuntimeFeatures.c_text(features)
          sound_text = RuntimeFeatures.c_text(features, joins: :sound)
          dir = File.join(Dir.tmpdir, "vblank-native", "src-#{Digest::SHA256.hexdigest(text + numbers + screen_text + sound_text)[0, 24]}")
          path = File.join(dir, Lowering::GAME_FILE)
          return path if File.exist?(path)

          FileUtils.mkdir_p(dir)
          # game.c last: a folder holding it is whole.
          { ConsoleNumbers::FILE => numbers, FEATURES_FILE => screen_text, SOUND_FEATURES_FILE => sound_text,
            **files.except(Lowering::GAME_FILE), Lowering::GAME_FILE => text }.each do |name, body|
            writing = File.join(dir, "#{name}.#{Process.pid}.#{rand(1 << 30)}")
            File.binwrite(writing, body)
            File.rename(writing, File.join(dir, name))
          end
          path
        end
      end
    end
  end
end
