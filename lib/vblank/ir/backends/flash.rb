# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require_relative "flash/haxe"
require_relative "flash/printer"
require_relative "flash/lowering"
require_relative "flash/headless_run"
require_relative "flash/checked_run"

module VBlank
  module IR
    module Backends
      # The game as a Flash program (a .swf), played in Ruffle, the open-source Flash player: a computer
      # build, made as the JavaScript build is.
      #
      # How it is made. Computer::Lowering already writes a program as a tree of statements and calls into a
      # runtime, with no operator anywhere on a game's number (see the comment atop Native);
      # Flash::Lowering prints that same tree as Haxe (Printer), and the runtime is runtime/*.hx, the
      # JavaScript runtime written again in Haxe, function for function. Haxe (Flash::Haxe) compiles the
      # printed game and the runtime into one movie, as zig does for the C build. Everything is one class,
      # Main: each runtime file is a part of it (RUNTIME), and the game is the rest, so the game calls every
      # runtime function by its bare name, as it does in the other builds.
      #
      # Three things are Flash's own:
      #
      # - A number. Haxe's Int is the movie's 32-bit int, but a product of two is worked out as a float, so
      #   the arithmetic is runtime/rg_int32.hx, which puts a product together from halves and brings every
      #   answer back to 32 bits (the same discipline rg_int32.h keeps in C).
      # - A frame. A movie gives control back only when a handler ends, so a routine that can wait is
      #   resumable (see Printer), and a driver plays the game a pass at a time from each ENTER_FRAME.
      # - A driver is what the game runs on: runtime/rg_headless.hx, which the tests play in the harness
      #   of ruby-flash-player/ and which prints what the native headless program prints, so a test drives
      #   either the same way (HeadlessRun).
      #
      # What the runtime cannot do yet is refused by name, before the game is played: the functions the
      # printed game calls that no runtime file defines, and the runtime features with no Haxe file
      # (RuntimeGap, a skip in the Flash run).
      class Flash
        # Raised when a program cannot be written as Haxe. The same error every lowering for a computer
        # raises, since most of what refuses a program is the lowering they share.
        LoweringError = Computer::LoweringError

        RUNTIME_DIR = Ractor.make_shareable(File.expand_path("flash/runtime", __dir__))

        # The runtime every program carries, in the order it is put together, and the drivers that follow it.
        RUNTIME = Ractor.make_shareable(%w[rg_int32.hx rg_runtime.hx rg_list.hx rg_screen.hx rg_state.hx])
        TYPES = "rg_types.hx"
        # The Haxe files of its own the runtime compiles beside the game (see #compile), read once: what they say is part of what a movie is.
        OVERRIDES_TEXT = Ractor.make_shareable(Dir.glob(File.join(RUNTIME_DIR, "overrides", "**", "*.hx")).sort.map { |path| File.read(path) }.join("\n"))
        HEADLESS_DRIVER = "rg_headless.hx"
        PAGE_DRIVER = "rg_page.hx"

        # Every function a program's runtime defines, read from its files and every runtime feature's that has
        # a Haxe file, for each driver: what Lowering#text_and_gaps holds a program's calls against.
        def self.functions_in(paths) = paths.flat_map { |path| File.read(path).scan(/^static (?:inline )?function (\w+)/).flatten }.uniq

        def self.runtime_paths(names)
          names.map { |name| File.join(RUNTIME_DIR, name) } + RuntimeFeatures.every_file("hx").select { |path| File.file?(path) }
        end

        HEADLESS_FUNCTIONS = Ractor.make_shareable(functions_in(runtime_paths(RUNTIME + [HEADLESS_DRIVER])))
        PAGE_FUNCTIONS = Ractor.make_shareable(functions_in(runtime_paths(RUNTIME + [PAGE_DRIVER])))

        # The keys on a Flash keyboard (flash.ui.Keyboard's key codes) for the keys a game's layout names
        # (IR::ComputerControls): each as its code, and the side it must be on (2 for the right, 0 for either).
        OTHER_KEY_CODES = Ractor.make_shareable({ enter: [13, 0], escape: [27, 0], backspace: [8, 0], tab: [9, 0], space: [32, 0],
                                                  minus: [189, 0], right: [39, 0], left: [37, 0], down: [40, 0], up: [38, 0],
                                                  right_shift: [16, 2], left_shift: [16, 0] })

        # Raised when a program needs something the runtime cannot do yet, naming the +part+ it needs: a test
        # asks it as it asks a question the lowering cannot answer, and the Flash run skips it under that
        # part's name (Testing::FlashCheckedPlayer).
        class RuntimeGap < Computer::HeadlessRun::CannotAnswer
          attr_reader :part

          def initialize(part, message)
            @part = part
            super(message)
          end
        end

        # The first line of everything the backend writes.
        WRITTEN_BY = "// Written by VBlank's Flash backend. Do not edit; build the game again.\n"

        # The movie built to run with no window (runtime/rg_headless.hx), and the path to it: it is played in
        # the harness, which answers what it asks (see rg_headless.hx for how it is run and what it prints).
        def build_headless(program)
          lowering = Lowering.new(program)
          text, gaps = lowering.text_and_gaps(HEADLESS_FUNCTIONS)
          refuse_runtime_gaps!(gaps)
          source = class_text(lowering, text, HEADLESS_DRIVER)
          width, height = program.described_console.framed_screen_size
          compile(source, width: width, height: height)
        end

        # +game+ as a Flash movie, written to +path+ (game.swf): the game checked as a cartridge build checks it,
        # written as Haxe and compiled with the runtime that draws on a stage, which a person plays with the
        # keyboard (runtime/rg_page.hx). +scale+ is how many times the console's picture is enlarged.
        # +console+ is the one the game is built as, the first it names when left out.
        def build_swf(game, path, console: nil, settings: {}, scale: 3, err: $stderr, progress: Messages::Progress.silent,
                      pack_at_start: false, trace_pictures: false)
          raise LoweringError, "#{path} is a folder, so the game cannot be written there. Name a file instead." if File.directory?(path)

          program = Computer::CheckedProgram.build(game, console: console, settings: settings, err: err, progress: progress,
                                                          pack_at_start: pack_at_start)
          progress.step("Writing Haxe")
          lowering = Lowering.new(program, title: game.title)
          text, gaps = lowering.text_and_gaps(PAGE_FUNCTIONS)
          unless gaps.empty?
            raise LoweringError, "this game cannot be built for Flash yet: the Flash build does not have #{gaps.join(', ')}. " \
                                 "The cartridge build and the web build can."
          end
          progress.step("Compiling with Haxe")
          width, height = program.described_console.framed_screen_size
          source = class_text(lowering, text, PAGE_DRIVER, extra: page_text(program, scale))
          defines = trace_pictures ? %w[rg_trace_pictures] : []
          FileUtils.cp(compile(source, width: width * scale, height: height * scale, defines: defines), path)
          progress.done
          path
        end

        private

        # The scale the picture is shown at and which key is which button, ahead of the page driver, which reads them.
        def page_text(program, scale) = "static inline var RG_PAGE_SCALE:Int = #{Integer(scale)};\n#{keys_text(program)}"

        # RG_KEYS: four numbers for each key of the layout, the key's code, the side it is on, the player it is for
        # (counted from 0) and the button's bit. The console's buttons alone have keys; player 2's only where the
        # game seats more than one player.
        def keys_text(program)
          buttons = program.described_console.buttons
          bit = ->(button) { Buttons::NAMES.index(button) }
          rows = ComputerControls::LAYOUT_KEYS.slice(*buttons).flat_map do |button, keys|
            keys.map { |key| [*flash_key(key), 0, bit.call(button)] }
          end
          if (program.max_players || 1) > 1
            ComputerControls::SECOND_PLAYER_KEYS.each do |key, button|
              rows << [*flash_key(key), 1, bit.call(button)] if buttons.include?(button)
            end
          end
          "static var RG_KEYS:Vector<Int> = Vector.fromArrayCopy([#{rows.flatten.join(', ')}]);\n"
        end

        # A key as its Flash code and side.
        def flash_key(key)
          return [48 + key, 0] if key.is_a?(Integer)
          return [65 + (key.to_s.ord - "a".ord), 0] if ComputerControls::LETTER_KEYS.key?(key)

          OTHER_KEY_CODES.fetch(key) { raise LoweringError, "the Flash build has no key code for #{key.inspect}" }
        end

        def refuse_runtime_gaps!(gaps)
          return if gaps.empty?

          raise RuntimeGap.new(gaps.first, "the Flash lowering cannot play this game yet: its runtime does not have #{gaps.join(', ')}")
        end

        # The one class the movie is: the console's numbers, the runtime, the runtime features, the game and
        # the driver, then the classes the runtime keeps things in.
        def class_text(lowering, game_text, driver, extra: "")
          ["import haxe.ds.Vector;\n\nclass Main {\n", lowering.console_text, extra, *runtime_text(RUNTIME),
           RuntimeFeatures.hx_text(lowering.runtime_features), game_text, *runtime_text([driver]), "}\n\n",
           *runtime_text([TYPES])].join
        end

        def runtime_text(names) = names.map { |name| File.read(File.join(RUNTIME_DIR, name), encoding: Encoding::UTF_8) }

        # +source+ compiled, with the runtime's own copy of the one Haxe file Ruffle cannot run (overrides/), in a folder named for what it holds so two programs never write over each other:
        # written and compiled under names of its own and then renamed into place, so two tests building the
        # same game at once each put down a whole file.
        def compile(source, width:, height:, defines: [])
          dir = File.join(Dir.tmpdir, "vblank-flash", Digest::SHA256.hexdigest([source, OVERRIDES_TEXT, *defines].join("\n"))[0, 24])
          swf = File.join(dir, "game.swf")
          return swf if File.exist?(swf)

          FileUtils.mkdir_p(dir)
          working = File.join(dir, "build-#{Process.pid}-#{rand(1 << 30)}")
          FileUtils.mkdir_p(working)
          FileUtils.cp_r(File.join(RUNTIME_DIR, "overrides", "."), working)
          File.write(File.join(working, "Main.hx"), WRITTEN_BY + source)
          Haxe.compile(working, main: "Main", swf: File.join(working, "game.swf"), width: width, height: height, defines: defines)
          FileUtils.mv(File.join(working, "Main.hx"), File.join(dir, "Main.hx"))
          File.rename(File.join(working, "game.swf"), swf)
          FileUtils.remove_entry(working)
          swf
        end
      end
    end
  end
end
