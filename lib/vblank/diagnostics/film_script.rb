# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A FILM WRITTEN AS A SMALL FILE: which frames to show, the buttons held on each, and how each
    # side reaches the moment before the first. FilmTasks reads one by name and makes the film, and
    # the sides it opens are the ones the Rakefile names, unless the file names its own.
    #
    #   # films/door.rb
    #   parts 1..90, 200..240           # frames to show, counted from where each side starts
    #   hold :right, on: 10..80         # a button down on those frames
    #   hold %i[a b], on: 85            # two buttons, on one frame
    #   keys { |frame| :start if frame == 210 }  # or give the buttons of any frame in Ruby
    #
    # The file is Ruby, so it can `require` what the game's tests use to reach a moment, and these
    # are the words it has besides:
    #
    #   parts 1..90, 200..240           the ranges of frames shown, counted from one
    #   hold :a, on: 4..5               buttons down on a frame or a range of them; as many as needed
    #   keys { |frame| ... }            the buttons down on a frame: a name, a list, or nil. A Hash
    #                                   of frame to buttons works too (`keys LAUNCH`), as does a lambda.
    #                                   What `hold` and `keys` give for one frame are held together.
    #   start_from tape: "walk.tape"    every side plays a tape's presses first (from power-on)
    #   start_from state: { "ours" => "ours.ss1", "retail" => "retail.ss1" }
    #                                   each side starts from a state an emulator saved of it
    #   side "old", "builds/old.gba"    a side of this film's own: a cartridge's path, a built one, a
    #   side("ours") { ... }            game to build, or a block answering any of them, or a running
    #                                   cartridge (see Film)
    #   side "ps1", GAME, console: :ps1, lowering: "ruby"
    #                                   ...built for that console, played that way (FilmCartridge);
    #                                   unsaid, the Rakefile's or the command line's
    #   scale 3                         each picture at three times the console's size (two if unsaid)
    #
    # A frame number counts from where the side starts: from power-on, after the tape, or after the
    # state. A side the file names replaces the Rakefile's side of the same label, and is added if
    # the Rakefile has none.
    #
    # One more word takes everything at once, for a film already written as a call to Film.make:
    #
    #   film sides: { "ours" => -> { ... } }, parts: [1..110], keys: ->(frame) { ... }
    class FilmScript
      # What a film file asks for, once read: made into an MP4 by #make.
      Plan = Data.define(:parts, :holds, :keys, :sides, :tape, :states, :scale, :console, :lowering) do
        # Write the film to +path+, handed back. +search_path+ is where ImageMagick and ffmpeg are
        # looked for (see Film.make).
        def make(path, search_path: ENV.fetch("PATH", ""))
          openers = sides.to_h { |label, side| [label, -> { open_side(label, side) }] }
          Film.make(path, sides: openers, parts: parts, keys: ->(frame) { buttons_on(frame) }, scale: scale, search_path: search_path)
        end

        # The buttons down on +frame+: what `keys` gives, and every hold over that frame.
        def buttons_on(frame)
          held = holds.select { |hold| hold.frames.cover?(frame) }.flat_map(&:buttons)
          (Array(keys&.call(frame)) + held).uniq
        end

        private

        # A side's game, opened at the moment before the film's first frame. A block or lambda
        # is called first; what it gives back that is already running is filmed as it stands. The
        # console and lowering are the side's own where the film file named them, else the film's.
        def open_side(label, side)
          side = Side.new(game: side, console: nil, lowering: nil) unless side.is_a?(Side)
          cartridge = side.game.respond_to?(:call) ? side.game.call : side.game
          state = states.is_a?(Hash) ? states[label] : states
          unless running?(cartridge)
            return FilmCartridge.open(cartridge, tape: tape, state: state, console: side.console || console,
                                                 lowering: side.lowering || lowering)
          end
          return cartridge unless tape || state

          raise ArgumentError, "The side \"#{label}\" is already running, so it cannot start from a tape or a saved " \
                               "state. Remove `start_from`, or give the side a cartridge in place of a running one."
        end

        def running?(cartridge) = cartridge.respond_to?(:step) && cartridge.respond_to?(:screenshot)
      end
      # Buttons down on a range of frames.
      Hold = Data.define(:buttons, :frames)

      # A side the film file names, with the console and lowering it names (nil where it names none).
      Side = Data.define(:game, :console, :lowering)

      # The film in the file at +path+, with +sides+ (label to cartridge) the ones its Rakefile names.
      # +console+ and +lowering+ are what every side is opened with unless it sets its own (see
      # FilmCartridge); a name that is no console's or no lowering's is refused before any side opens.
      def self.read(path, sides: {}, console: nil, lowering: nil)
        script = new(path, sides: sides, console: console, lowering: lowering)
        script.instance_eval(File.read(path), path.to_s, 1)
        script.plan
      end

      def initialize(path, sides:, console: nil, lowering: nil)
        @path = path.to_s
        @console = console_named(console)
        @lowering = lowering_named(lowering)
        @sides = sides.transform_keys(&:to_s)
        @parts = nil
        @holds = []
        @keys = nil
        @tape = nil
        @states = {}
        @scale = Film::PICTURE_SCALE
      end

      def parts(*ranges)
        @parts = ranges.flatten
      end

      def hold(buttons, on:)
        frames = on.is_a?(Integer) ? on..on : on
        refuse_bad_hold!(buttons, frames)
        @holds << Hold.new(buttons: Array(buttons), frames: frames)
      end

      def keys(table = nil, &block)
        given = table || block
        refuse_bad_keys!(given)
        @keys = given.is_a?(Hash) ? ->(frame) { given[frame] } : given
      end

      def start_from(tape: nil, state: nil)
        refuse_bad_start!(tape, state)
        @tape = tape
        @states = state.is_a?(Hash) ? state.transform_keys(&:to_s) : state
      end

      def side(label, cartridge = nil, console: nil, lowering: nil, &block)
        refuse_bad_side!(label, cartridge, block)
        @sides[label.to_s] = Side.new(game: cartridge || block, console: console_named(console),
                                      lowering: lowering_named(lowering))
      end

      def scale(times)
        @scale = times
      end

      def film(sides:, parts:, keys: nil)
        sides.each { |label, cartridge| side(label, cartridge) }
        parts(*parts)
        keys(keys) if keys
      end

      # What the file asks for, refused here if it never names which frames to show.
      def plan
        if @parts.nil?
          raise ArgumentError, "The film #{@path} does not say which frames to show. Add a line like `parts 1..90`."
        end
        if @sides.empty?
          raise ArgumentError, "The film #{@path} has no side to film. Name the sides in the Rakefile with `t.sides = " \
                               "{ \"ours\" => \"game.gba\" }`, or in the film with `side \"ours\", \"game.gba\"`."
        end

        Plan.new(parts: @parts, holds: @holds, keys: @keys, sides: @sides, tape: @tape, states: @states, scale: @scale,
                 console: @console, lowering: @lowering)
      end

      private

      # A console's name as its Symbol, or nil for none; one no console has is refused here, before any
      # side opens, by the list of consoles (Console.named).
      def console_named(console) = console && Console.named(console)

      # A way to show a game, as given, or nil for none; one that is not a way is refused here by the
      # list of ways (Playthroughs::CommandLine.shown_way_named).
      def lowering_named(lowering)
        Playthroughs::CommandLine.shown_way_named(lowering)
        lowering&.to_s
      end

      def refuse_bad_hold!(buttons, frames)
        return if frames.is_a?(Range) && frames.begin.is_a?(Integer) && frames.begin >= 1 && (buttons.is_a?(Symbol) || buttons.is_a?(Array))

        raise ArgumentError, "`hold #{buttons.inspect}, on: #{frames.inspect}` in #{@path} is not a hold. Give a " \
                             "button or a list of buttons, and a frame or a range of frames from 1: `hold :a, on: 4..5`."
      end

      def refuse_bad_keys!(given)
        return if given.is_a?(Hash) || given.respond_to?(:call)

        raise ArgumentError, "`keys` in #{@path} was given #{given.inspect}. Give a block, a lambda, or a Hash of frame " \
                             "to buttons: `keys { |frame| :a if frame == 30 }`."
      end

      def refuse_bad_start!(tape, state)
        return if tape.nil? ^ state.nil?

        raise ArgumentError, "`start_from` in #{@path} must name a tape or a saved state, and not both: " \
                             "`start_from tape: \"walk.tape\"`."
      end

      def refuse_bad_side!(label, cartridge, block)
        return if (label.is_a?(String) || label.is_a?(Symbol)) && (cartridge.nil? ^ block.nil?)

        raise ArgumentError, "`side #{label.inspect}` in #{@path} must have a label and a cartridge, or a label and a " \
                             "block: `side \"old\", \"builds/old.gba\"`."
      end
    end
  end
end
