# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Diagnostics
    # ONE SIDE OF A FILM, OPENED: a game running, brought to the moment before the film's first frame,
    # with a save folder of its own. What Film asks of a side, it answers (`step`, `screenshot`,
    # `close`).
    #
    #   FilmCartridge.open("builds/old.gba")                      # from power-on
    #   FilmCartridge.open(rom, tape: "launch.tape")              # after a tape's presses
    #   FilmCartridge.open("retail.gbc", state: "at_door.ss1")    # from a state an emulator saved
    #   FilmCartridge.open(GAME, console: :ps1)                   # a game built for the PlayStation
    #   FilmCartridge.open(GAME, lowering: "ruby")                # the game built as Ruby
    #
    # THE GAME is a path to a cartridge file (one this framework built, or one it did not), a built
    # cartridge, or a game to build (what `VBlank.game` hands back). A game to build is built once and
    # not measured; a side that wants the measured cartridge builds it itself (`-> { GAME.build_rom }`).
    #
    # +console:+ (a console's name, :gba, :gbc, :snes, :genesis or :ps1) says which console a game to
    # build is built for: the first one it names unless set. A built cartridge or a cartridge file is
    # already for one console, which says which emulator plays it (Console::Kit#open_probe), so there
    # +console:+ only checks: a side that names another console is refused, saying which the file is
    # for.
    #
    # +lowering:+ says how the game is shown (Playthroughs::CommandLine::SHOWN_WAYS): the cartridge in
    # its console's emulator unless set, or the game played as the interpreter, native, js or ruby
    # plays it (Playthroughs::LoweredGame). Those take the game itself, so a cartridge file is shown
    # only in the emulator. They play the game the cartridge holds — `built_for_computer?` answers
    # false, as it does in the cartridge — so the two sides of one game show one game.
    #
    # WHERE IT STARTS. From power-on, the film's frame 1 is the first frame the console plays. After
    # a tape, it is the frame after the tape's last; from a saved state, the frame after the state
    # was saved. Either way the parts of a film count from that moment. A saved state is the
    # emulator's own, so only a cartridge in the emulator starts from one.
    #
    # A SAVE FOLDER OF ITS OWN. The emulator keeps a cartridge's save memory in a file named for the
    # cartridge. Two runs sharing a folder would find each other's saves, and a retail cartridge's
    # save next to it would change the game the film shows. So every cartridge opened here gets an
    # empty folder, and closing it takes the folder away.
    class FilmCartridge
      # HOW LONG A CARTRIDGE TAKES TO SHOW ITS FIRST PASS, in frames, by console and by the screen the
      # game starts on. A cartridge powers on, sets up and only then reaches the game loop, and a
      # console that copies a pass's picture to the screen in the blank after it (the Color, the Super
      # Nintendo) shows a pass a frame later still; a lowering starts at the game's first statement and
      # shows its first pass on its first frame. So a lowering's side is held back this many frames, and
      # the two sides of one game show the same pass on the same frame of the film.
      #
      # Measured, not derived: an animated game filmed both ways, and the frame of the lowering each
      # frame of the cartridge matched. test_film_cartridge.rb (the Advance) and test_ps1_film.rb pin
      # their numbers. Testing::Pictures keeps the same kind of table for the checked runs, counted
      # from another moment, so its numbers are not these.
      CARTRIDGE_START_FRAMES = Ractor.make_shareable({ gba: { bitmap: 1, tiled: 1, rotozoom: 1 },
                                                       gbc: { bitmap: 9, tiled: 6 }, snes: { bitmap: 8, tiled: 6 },
                                                       ps1: { bitmap: 1 } })

      # A console and screen nobody has measured (the Genesis's, whose cartridge cannot be filmed yet).
      UNMEASURED_START_FRAMES = 1

      # The folder this cartridge's save memory is kept in while it runs.
      attr_reader :save_dir

      def self.open(game, tape: nil, state: nil, console: nil, lowering: nil)
        new(game, tape: tape, state: state, console: console, lowering: lowering)
      end

      def initialize(game, tape: nil, state: nil, console: nil, lowering: nil)
        refuse_tape_and_state!(tape, state)
        console = Console.named(console) if console
        way = Playthroughs::CommandLine.shown_way_named(lowering)
        refuse_state_on_lowering!(lowering) if state && way
        @save_dir = Dir.mktmpdir("film-save")
        @frames_held_back = 0
        @blank = false
        @reader = way ? open_lowering(program_from(game, console), way) : open_cartridge(game, console)
        @reader.load_state(state) if state
        play_tape(Playthroughs::Tape.read(tape.to_s)) if tape
      rescue StandardError
        close
        raise
      end

      # Play +count+ frames with the buttons +keys+ down (IR::Buttons.mask). A lowering held back for the
      # cartridge's start-up spends those frames first, with the game not yet running, so the buttons
      # down then reach no game, as on the console.
      def step(count = 1, keys: 0)
        waiting = [@frames_held_back, count].min
        @frames_held_back -= waiting
        @reader.step(count - waiting, keys: keys) if count > waiting
        @blank = false if count > waiting
        self
      end

      def screenshot(path)
        return @reader.screenshot(path) unless @blank

        # Before its first pass a lowering shows the picture a display switched off shows.
        width = @reader.screen_width
        height = @reader.screen_height
        Graphics::PNG.write(path, width: width, height: height,
                                  pixels: Array.new(width * height, IR::Backends::Reference::Framebuffer::HELD_OFF))
      end

      # Shut the emulator and take the save folder away.
      def close
        @reader&.close
        FileUtils.remove_entry(@save_dir, true) if @save_dir
        nil
      end

      private

      # The game played as a lowering, held back to start where the cartridge does (CARTRIDGE_START_FRAMES).
      def open_lowering(program, way)
        @frames_held_back = cartridge_start_frames(program)
        @blank = true
        Playthroughs::LoweredGame.new(program, way)
      end

      # The frames +program+'s cartridge plays before the frame that shows its first pass, by its
      # console and the screen it starts on.
      def cartridge_start_frames(program)
        screen = program.walk.find { |node| node.kind == :screen }&.mode || :bitmap
        CARTRIDGE_START_FRAMES.dig(program.described_console.name, screen) || UNMEASURED_START_FRAMES
      end

      # The cartridge in the emulator its console's kit names (Console::Kit#open_probe), through the
      # one reader.
      def open_cartridge(game, console)
        cartridge = if game_to_build?(game)
                      game.build_rom(out: nil, profile: false, **{ console: console }.compact)
                    else
                      finished_cartridge(game, console)
                    end
        Verifier.new(cartridge, frames: 0, save_dir: @save_dir)
      end

      # The checked program a lowering plays, as the cartridge holds it: the game's, for the console
      # said, or the one a built cartridge was made from. A cartridge file holds none.
      def program_from(game, console)
        return game.checked_program(for_computer: false, **{ console: console }.compact) if game_to_build?(game)

        finished_cartridge(game, console).source_program or
          raise ArgumentError, "A cartridge file can be shown only in the emulator, and this side gives a lowering. " \
                               "To show the game another way, give the game or a cartridge built here. To show the " \
                               "file, leave out `lowering:`."
      end

      def game_to_build?(game) = game.respond_to?(:build_rom) && game.respond_to?(:checked_program)

      # A built cartridge as it is, or a cartridge file read from its path, when it is for +console+.
      def finished_cartridge(game, console)
        cartridge = game.respond_to?(:console) && game.respond_to?(:write) ? game : CartridgeFile.new(game.to_s)
        refuse_other_console!(cartridge, console)
        cartridge
      end

      # A cartridge is for one console, and its emulator is that console's.
      def refuse_other_console!(cartridge, console)
        return if console.nil? || cartridge.console == console

        it = Console.described(cartridge.console)
        said = Console.described(console)
        raise ArgumentError, "This side is a #{it.title} cartridge, and it says `console: :#{console}`, the " \
                             "#{said.title}. A cartridge plays only on its own console. To fix this, give " \
                             "`console: :#{cartridge.console}`, or leave out `console:`."
      end

      # Every press on the tape, a stretch of frames with the same buttons down at a time.
      def play_tape(tape)
        refuse_unplayable_tape!(tape)
        tape.presses_within(1..tape.frames).each do |stretch|
          step(stretch.frames.size, keys: IR::Buttons.mask(stretch.buttons))
        end
      end

      def refuse_tape_and_state!(tape, state)
        return unless tape && state

        raise ArgumentError, "A side of a film was told to start after a tape and from a saved state. A side can start " \
                             "from one of them only. Give `tape:` or `state:`."
      end

      def refuse_state_on_lowering!(lowering)
        raise ArgumentError, "A saved state is the emulator's own, and this side shows the game on #{lowering}. Only " \
                             "the cartridge in the emulator can start from a saved state. To fix this, leave out " \
                             "`lowering:`, or start from a tape."
      end

      # A tape of passes holds no frame count, and one recorded from a save or after a lead-in
      # plays a different game from power-on.
      def refuse_unplayable_tape!(tape)
        if tape.in_passes
          raise ArgumentError, "The tape counts passes of the game loop, and a film counts frames. Record the tape in " \
                               "frames, or write it out with `tape.in_frames_on(cartridge)`."
        end
        return if tape.starts_from == Playthroughs::Tape::POWER_ON

        raise ArgumentError, "The tape starts from #{tape.starts_from}. A film plays a tape from power-on, so these " \
                             "presses would play a different game. Use a tape recorded from power-on."
      end
    end
  end
end
