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
    #   start_from :game                the Rakefile's shell (FilmTasks#shell) is filmed from its game's
    #                                   first frame, with its menu and unpacking played first, unfilmed
    #   side "old", "builds/old.gba"    a side of this film's own: a cartridge's path, a built one, a
    #   side("ours") { ... }            game to build, or a block answering any of them, or a running
    #                                   cartridge (see Film)
    #   side "ps1", GAME, console: :ps1, lowering: "ruby"
    #                                   ...built for that console, played that way (FilmCartridge);
    #                                   unsaid, the Rakefile's or the command line's
    #   scale 3                         each picture at three times the console's size (two if unsaid)
    #   sound "ours"                    hear that side (Film.make's +sound:+, FilmSound); or
    #   sound :side_by_side             two sides, one on each speaker; or
    #   sound :in_turn                  the film shown once for each side, one heard each time.
    #                                   Unsaid, the Rakefile's or the command line's; none if unsaid there
    #
    # A frame number counts from where the side starts: from power-on, after the tape, or after the
    # state. A shell's two sides count from its menu, or from its game's first frame after
    # `start_from :game`, which is the same frame on any machine however long the unpacking takes;
    # a cartridge side beside them still starts from power-on. A side the file names replaces the
    # Rakefile's side of the same label, and is added if the Rakefile has none.
    #
    # One more word takes everything at once, for a film already written as a call to Film.make:
    #
    #   film sides: { "ours" => -> { ... } }, parts: [1..110], keys: ->(frame) { ... }, sound: "ours"
    class FilmScript
      # What a film file asks for, once read: made into an MP4 by #make.
      Plan = Data.define(:parts, :holds, :keys, :sides, :tape, :states, :scale, :console, :lowering, :shell, :shell_from,
                         :sound) do
        # Write the film to +path+, handed back. +search_path+ is where ImageMagick and ffmpeg are
        # looked for (see Film.make).
        def make(path, search_path: ENV.fetch("PATH", ""))
          Film.make(path, sides: side_openers, parts: parts, keys: ->(frame) { buttons_on(frame) }, scale: scale,
                          sound: sound, search_path: search_path)
        end

        # Each side's label to the lambda that opens it, in the order Film plays them (Film.make's
        # +sides:+): the shell's two sides first, where there is a shell, then the others. A side
        # the film file names replaces the shell's side of that label in its place. Each side heard
        # (+sound+) is opened keeping its sound.
        def side_openers
          heard = heard_labels
          shell_openers(heard).merge(sides.to_h { |label, side| [label, -> { open_side(label, side, heard.include?(label)) }] })
        end

        # The labels of the sides heard (FilmSound.heard_labels), none without +sound+; a +sound+ naming
        # no side is refused.
        def heard_labels
          return [] if sound.nil?

          FilmSound.heard_labels(sound, (shell ? [SHELL_LABEL, ALL_IN_ONE_LABEL] : []) | sides.keys)
        end

        # The buttons down on +frame+: what `keys` gives, and every hold over that frame.
        def buttons_on(frame)
          held = holds.select { |hold| hold.frames.cover?(frame) }.flat_map(&:buttons)
          (Array(keys&.call(frame)) + held).uniq
        end

        private

        # The shell's side and the all-in-one build's beside it (FilmShell), sharing one shell built
        # when the first of them opens; none without a shell.
        def shell_openers(heard)
          return {} unless shell

          film_shell = nil
          build_shell = -> { film_shell ||= FilmShell.new(shell.respond_to?(:call) ? shell.call : shell, console: console) }
          { SHELL_LABEL => -> { build_shell.call.open(from: shell_from, sound: heard.include?(SHELL_LABEL)) },
            ALL_IN_ONE_LABEL => -> { build_shell.call.all_in_one(sound: heard.include?(ALL_IN_ONE_LABEL)) } }
        end

        # A side's game, opened at the moment before the film's first frame. A block or lambda
        # is called first; what it gives back that is already running is filmed as it stands. The
        # console and lowering are the side's own where the film file named them, else the film's.
        # A side +heard+ keeps its sound.
        def open_side(label, side, heard)
          side = Side.new(game: side, console: nil, lowering: nil) unless side.is_a?(Side)
          cartridge = side.game.respond_to?(:call) ? side.game.call : side.game
          state = states.is_a?(Hash) ? states[label] : states
          unless running?(cartridge)
            return FilmCartridge.open(cartridge, tape: tape, state: state, console: side.console || console,
                                                 lowering: side.lowering || lowering, sound: heard)
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

      # The labels of the two sides a shell is filmed as (FilmShell#open and #all_in_one).
      SHELL_LABEL = "shell"
      ALL_IN_ONE_LABEL = "all-in-one"

      # The film in the file at +path+, with +sides+ (label to cartridge) the ones its Rakefile names.
      # +console+ and +lowering+ are what every side is opened with unless it sets its own (see
      # FilmCartridge); a name that is no console's or no lowering's is refused before any side opens.
      # +shell+ is a port (or a lambda answering one) whose shell is filmed as two sides, SHELL_LABEL
      # and ALL_IN_ONE_LABEL, before the others (FilmShell); always played as Ruby, whatever +lowering+.
      # +sound+ is which side is heard (Film.make's +sound:+) unless the file says: none if nil.
      def self.read(path, sides: {}, console: nil, lowering: nil, shell: nil, sound: nil)
        script = new(path, sides: sides, console: console, lowering: lowering, shell: shell, sound: sound)
        script.evaluate_file
        script.plan
      end

      # The film file's words run on this script. Evaluated here, where no local variable is in scope:
      # in a method with a local named like a word (`sound`), the file's word would read the local.
      def evaluate_file = instance_eval(File.read(@path), @path, 1)

      def initialize(path, sides:, console: nil, lowering: nil, shell: nil, sound: nil)
        @path = path.to_s
        @console = console_named(console)
        @lowering = lowering_named(lowering)
        @sides = sides.transform_keys(&:to_s)
        @shell = shell
        @sound = sound
        @shell_from = :menu
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

      def start_from(place = nil, tape: nil, state: nil)
        refuse_bad_start!(place, tape, state)
        @shell_from = place if place
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

      def sound(heard)
        @sound = heard
      end

      def film(sides:, parts:, keys: nil, sound: nil)
        sides.each { |label, cartridge| side(label, cartridge) }
        parts(*parts)
        keys(keys) if keys
        sound(sound) if sound
      end

      # What the file asks for, refused here if it never names which frames to show.
      def plan
        if @parts.nil?
          raise ArgumentError, "The film #{@path} does not say which frames to show. Add a line like `parts 1..90`."
        end
        if @sides.empty? && @shell.nil?
          raise ArgumentError, "The film #{@path} has no side to film. Name the sides in the Rakefile with `t.sides = " \
                               "{ \"ours\" => \"game.gba\" }`, or in the film with `side \"ours\", \"game.gba\"`."
        end
        refuse_bad_shell_start!

        plan = Plan.new(parts: @parts, holds: @holds, keys: @keys, sides: @sides, tape: @tape, states: @states,
                        scale: @scale, console: @console, lowering: @lowering, shell: @shell, shell_from: @shell_from,
                        sound: @sound)
        plan.heard_labels # a +sound+ naming no side is refused before any side opens
        plan
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

      def refuse_bad_start!(place, tape, state)
        return if [place, tape, state].compact.size == 1 && (place.nil? || FilmShell::COUNTED_FROM.include?(place))

        raise ArgumentError, "`start_from` in #{@path} must name one place to start: a tape, a saved state, or the " \
                             "shell's game: `start_from tape: \"walk.tape\"` or `start_from :game`."
      end

      # A film started from the game counts from where the shell's game begins, so it needs a shell, and
      # the shell's sides play the shell's menu, not a tape or a saved state.
      def refuse_bad_shell_start!
        if @shell_from == :game && @shell.nil?
          raise ArgumentError, "The film #{@path} starts from the game of a shell. It has no shell to film. Name the " \
                               "port in the Rakefile with `t.shell = -> { GAME }`, or remove `start_from :game`."
        end
        return unless @shell && (@tape || states_given?)

        raise ArgumentError, "The film #{@path} films a shell. A shell starts at its menu, not from a tape or a saved " \
                             "state. Remove `start_from tape:` or `start_from state:`, or use `start_from :game`."
      end

      # True when `start_from state:` named a state for any side.
      def states_given? = @states.is_a?(Hash) ? !@states.empty? : !@states.nil?

      def refuse_bad_side!(label, cartridge, block)
        return if (label.is_a?(String) || label.is_a?(Symbol)) && (cartridge.nil? ^ block.nil?)

        raise ArgumentError, "`side #{label.inspect}` in #{@path} must have a label and a cartridge, or a label and a " \
                             "block: `side \"old\", \"builds/old.gba\"`."
      end
    end
  end
end
