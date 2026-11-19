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
    # +console:+ (a console's name, :gba, :gbc, :snes, :genesis or :ps1) names which console a game to
    # build is built for: the first one it names unless set. A built cartridge or a cartridge file is
    # already for one console, which decides which emulator plays it (Console::Kit#open_probe), so there
    # +console:+ only checks: a side that names another console is refused, saying which the file is
    # for.
    #
    # +lowering:+ chooses how the game is shown (Playthroughs::CommandLine::SHOWN_WAYS): the cartridge in
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
      # HOW LONG THE GAME'S CARTRIDGE TAKES TO SHOW ITS FIRST PASS, found for each game as its lowering
      # side opens. A cartridge powers on, sets up (copying the game's tiles and maps first, so a bigger
      # game takes longer) and only then reaches the game loop, and a console that copies a pass's
      # picture to the screen in the blank after it (the Color, the Super Nintendo) shows a pass a frame
      # later still. A lowering starts at the game's first statement and shows its first pass on its
      # first frame. So a lowering's side is held back the frames the cartridge plays before it shows
      # the picture of its first pass, and the two sides show the same pass on the same frame.
      #
      # LINED UP BY THE PICTURES, not by a count of frames per console: the game's cartridge is played in
      # the emulator beside the interpreter, and the frames held back are the first offset at which the
      # cartridge's pictures are the interpreter's, from the interpreter's first, for PICTURES_MATCHED
      # pictures that are not all one picture (so a still start cannot match early). A game whose first
      # STILL_PICTURES_SEARCHED pictures are all one is lined up on the first of them: before anything
      # moves, any offset looks the same. One whose cartridge never shows the interpreter's pictures in
      # LONGEST_START_FRAMES (a Genesis cartridge shows a sprite a pass after the interpreter does) is
      # lined up on the first frame its cartridge shows the interpreter's first picture, else not held
      # back at all.
      PICTURES_MATCHED = 4
      STILL_PICTURES_SEARCHED = 60
      LONGEST_START_FRAMES = 600

      # The folder this cartridge's save memory is kept in while it runs.
      attr_reader :save_dir

      # +sound:+ true keeps the sound a lowering makes, a frame at a time, for a film that hears this side
      # (#last_frame_samples). The emulator keeps a cartridge's sound whatever it is told.
      def self.open(game, tape: nil, state: nil, console: nil, lowering: nil, sound: false)
        new(game, tape: tape, state: state, console: console, lowering: lowering, sound: sound)
      end

      def initialize(game, tape: nil, state: nil, console: nil, lowering: nil, sound: false)
        refuse_tape_and_state!(tape, state)
        console = Console.named(console) if console
        way = Playthroughs::CommandLine.shown_way_named(lowering)
        refuse_state_on_lowering!(lowering) if state && way
        @save_dir = Dir.mktmpdir("film-save")
        @frames_held_back = 0
        @blank = false
        @silent_step = false
        @lowered_without_sound = way && !sound
        @reader = way ? open_lowering(cartridge_with_program(game, console), way, sound) : open_cartridge(game, console)
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
        @silent_step = count <= waiting
        self
      end

      # The samples of the frames just played, left and right by turns (Verifier#last_frame_samples,
      # Playthroughs::LoweredGame#last_frame_samples): none while a lowering is held back, when no game
      # is running yet.
      def last_frame_samples
        if @lowered_without_sound
          raise ArgumentError, "This side shows the game as a lowering and keeps no sound, so a film cannot hear it. " \
                               "To fix this, open it with `sound: true`: `FilmCartridge.open(game, lowering:, sound: true)`."
        end

        @silent_step ? [] : @reader.last_frame_samples
      end

      # The picture as a film asks for it, with no file: as #screenshot's.
      def screen_picture
        return @reader.screen_picture unless @blank

        width = @reader.screen_width
        height = @reader.screen_height
        Film::Picture.new(pixels: Array.new(width * height, IR::Backends::Reference::Framebuffer::HELD_OFF), width: width,
                          height: height)
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

      # The game +cartridge+ holds, played as a lowering, held back to start where the cartridge does
      # (#cartridge_start_frames), handing over its sound a frame at a time where +sound+ asks.
      def open_lowering(cartridge, way, sound)
        program = cartridge.source_program
        @frames_held_back = cartridge_start_frames(cartridge, program)
        @blank = true
        lowered = Playthroughs::LoweredGame.new(program, way, speaker: sound)
        refuse_silent_lowering!(lowered, way) if sound
        lowered
      end

      # The interpreter keeps a log of what the game asked of the sound chip, and makes no samples.
      def refuse_silent_lowering!(lowered, way)
        return if lowered.sound_rate

        lowered.close
        raise ArgumentError, "A film cannot hear a game shown as #{way}: it makes no sound samples. To fix this, " \
                             "show the side as ruby, js or native, or in the emulator, or do not hear this side."
      end

      # The frames +cartridge+ plays before the frame that shows the picture of its first pass: where its
      # pictures in the emulator line up with +program+'s on the interpreter (PICTURES_MATCHED and the
      # rest say how). The emulator plays in a save folder of its own, taken away after.
      def cartridge_start_frames(cartridge, program)
        expected = interpreter_pictures(program)
        Dir.mktmpdir("film-start") do |folder|
          reader = Verifier.new(cartridge, frames: 0, save_dir: folder)
          recent = []
          first_alike = nil
          LONGEST_START_FRAMES.times do |played|
            recent = (recent << reader.step(1, keys: 0).frame_gba).last(expected.size)
            first_alike ||= played if recent.last == expected.first
            return played + 1 - expected.size if recent == expected
          end
          first_alike || 0
        ensure
          reader&.close
        end
      end

      # The interpreter's first pictures of +program+: PICTURES_MATCHED, or more until one differs from the
      # rest, up to STILL_PICTURES_SEARCHED; the first alone when they never differ.
      def interpreter_pictures(program)
        interpreter = Playthroughs::LoweredGame.new(program, "interpreter")
        pictures = []
        until pictures.size >= PICTURES_MATCHED && pictures.uniq.size > 1
          return pictures.first(1) if pictures.size >= STILL_PICTURES_SEARCHED

          pictures << interpreter.step(1, keys: 0).frame_gba.dup
        end
        pictures
      ensure
        interpreter&.close
      end

      # A cartridge of +game+ that also holds the program it was built from, which a lowering plays:
      # the game built for +console+, or a cartridge built here. A cartridge file holds none.
      def cartridge_with_program(game, console)
        cartridge = game_to_build?(game) ? game.build_rom(out: nil, profile: false, **{ console: console }.compact) : finished_cartridge(game, console)
        cartridge.source_program or
          raise ArgumentError, "A cartridge file can be shown only in the emulator, and this side gives a lowering. " \
                               "To show the game another way, give the game or a cartridge built here. To show the " \
                               "file, leave out `lowering:`."
        cartridge
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
        tape.refuse_seed_frame_by_frame!("a film")
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
