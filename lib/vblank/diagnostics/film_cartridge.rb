# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module VBlank
  module Diagnostics
    # ONE SIDE OF A FILM, OPENED: a cartridge running in the emulator, brought to the moment before
    # the film's first frame, with a save folder of its own. What Film asks of a side, it answers
    # (`step`, `screenshot`, `close`).
    #
    #   FilmCartridge.open("builds/old.gba")                      # from power-on
    #   FilmCartridge.open(rom, tape: "launch.tape")              # after a tape's presses
    #   FilmCartridge.open("retail.gbc", state: "at_door.ss1")    # from a state an emulator saved
    #
    # THE CARTRIDGE is a path to a cartridge file (one this framework built, or one it did not), or
    # a built cartridge. Its console says how big its screen is, so a Color cartridge and an Advance
    # one are opened the same way.
    #
    # WHERE IT STARTS. From power-on, the film's frame 1 is the first frame the console plays. After
    # a tape, it is the frame after the tape's last; from a saved state, the frame after the state
    # was saved. Either way the parts of a film count from that moment.
    #
    # A SAVE FOLDER OF ITS OWN. The emulator keeps a cartridge's save memory in a file named for the
    # cartridge. Two runs sharing a folder would find each other's saves, and a retail cartridge's
    # save next to it would change the game the film shows. So every cartridge opened here gets an
    # empty folder, and closing it takes the folder away.
    class FilmCartridge
      # The folder this cartridge's save memory is kept in while it runs.
      attr_reader :save_dir

      def self.open(cartridge, tape: nil, state: nil) = new(cartridge, tape: tape, state: state)

      def initialize(cartridge, tape: nil, state: nil)
        refuse_tape_and_state!(tape, state)
        @save_dir = Dir.mktmpdir("film-save")
        @reader = Verifier.new(cartridge_from(cartridge), frames: 0, save_dir: @save_dir)
        @reader.load_state(state) if state
        play_tape(Playthroughs::Tape.read(tape.to_s)) if tape
      rescue StandardError
        close
        raise
      end

      # Play +count+ frames with the buttons +keys+ down (IR::Buttons.mask).
      def step(count = 1, keys: 0)
        @reader.step(count, keys: keys)
        self
      end

      def screenshot(path) = @reader.screenshot(path)

      # Shut the emulator and take the save folder away.
      def close
        @reader&.close
        FileUtils.remove_entry(@save_dir, true) if @save_dir
        nil
      end

      private

      def cartridge_from(cartridge)
        return cartridge if cartridge.respond_to?(:console) && cartridge.respond_to?(:write)

        CartridgeFile.new(cartridge.to_s)
      end

      # Every press on the tape, a stretch of frames with the same buttons down at a time.
      def play_tape(tape)
        refuse_unplayable_tape!(tape)
        tape.presses_within(1..tape.frames).each do |stretch|
          @reader.step(stretch.frames.size, keys: IR::Buttons.mask(stretch.buttons))
        end
      end

      def refuse_tape_and_state!(tape, state)
        return unless tape && state

        raise ArgumentError, "A side of a film was told to start after a tape and from a saved state. A side can start " \
                             "from one of them only. Give `tape:` or `state:`."
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
