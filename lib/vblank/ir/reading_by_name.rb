# frozen_string_literal: true

require "did_you_mean" # Offers the closest names in place of one a game never declared

module VBlank
  module IR
    # A RUNNING GAME'S STATE, ASKED BY THE NAMES THE GAME GAVE IT: a variable in the game's units, a
    # sprite, a background, the music's loudness. Every reader of a running game answers these the
    # same way, because each is this module over what that reader keeps: the interpreter and every
    # lowering's run (Backends::Reference::ReadingBack, which adds lists and pools), the cartridge
    # reader, a bot's view of its copy (Bots::GameView), and a moment a checked run recorded
    # (Backends::RunComparison::RecordedFrame).
    #
    # Whoever includes this defines #raw_var, a variable's stored number by its name (0 for one
    # never written), and #read_program, the program it plays (nil where it has none: a tree with
    # no program at its root, or a cartridge with no build record). Where the build put a sprite's
    # or a background's state is on the program (Program#sprite_readings), which reads it back
    # through this reader's #raw_var.
    module ReadingByName
      # A variable's number now, in the game's units: a fraction as the fraction.
      #
      # A NAME THE PROGRAM NEVER DECLARED IS REFUSED, not read as 0. A stored number nobody wrote is
      # 0, so without this a test left reading a name that a rename took away keeps passing every
      # assertion that the number stays 0. With no program to ask (a hand-built tree with no program
      # at its root), nothing says which names exist, and the stored number is all there is.
      def var(name)
        return raw_var(name) unless read_program

        refuse_undeclared_variable!(name) unless var?(name)
        read_program.var_in_game_units(name, raw_var(name))
      end

      def [](name) = var(name)

      # Whether the game has a variable +name+: one its program names anywhere, the framework's own
      # included. A script asks this before reading a variable only some builds of a game keep (a
      # game of one floor has no tally screen), rather than rescuing the error #var raises.
      def var?(name) = variables_named.include?(name)

      # A sprite by its name (`sprite :walker2, image: :walker`): an IR::SpriteState with its +x+,
      # +y+, whether it is #shown?, the +pose+ it is showing, its +angle+ and its +scale+.
      def sprite(name) = named_program("its sprites").sprite_state(name, self)

      # A background by its name: an IR::BackgroundState with how far it is scrolled and the +map+
      # the game has set showing.
      def background(name) = named_program("its backgrounds").background_state(name, self)

      # The music's loudness, 0 to 100, as the game's own `music_volume` reads it.
      def music_volume = named_program("its music").music_volume_from(self)

      private

      # Every variable the program names, worked out once for each program this reader plays: a script
      # can ask #var? on every frame, and the names are a walk of the whole tree. A frozen reader (a
      # recorded frame) keeps nothing, and walks each time.
      def variables_named
        program = named_program("its variables")
        return @variables_named.names if @variables_named&.program.equal?(program)

        named = VariablesNamed.new(program: program, names: Reach.variables(program).to_set)
        @variables_named = named unless frozen?
        named.names
      end

      # The variables +program+ names, kept beside the program they were worked out from.
      VariablesNamed = Data.define(:program, :names)

      # +name+, which the program never names, refused with the names closest to it the game gave,
      # or the first of its names where none is close (the framework's own, with two underscores in
      # front, are left out).
      def refuse_undeclared_variable!(name)
        own = variables_named.map(&:to_s).reject { |known| known.start_with?("__") }.sort
        closest = DidYouMean::SpellChecker.new(dictionary: own).correct(name.to_s)
        raise ArgumentError, "This game has no variable #{name.inspect}. #{names_offered_message(closest, own)} " \
                             "To ask if a variable exists, use var?(#{name.inspect})."
      end

      # The most names an unknown-variable error lists where none is close.
      NAMES_LISTED_MOST = 20

      # The sentence that offers +closest+ in place of a name, or the first of +own+ where nothing is close.
      def names_offered_message(closest, own)
        said = ->(names) { names.map { |known| ":#{known}" }.join(", ") }
        return "The closest #{closest.size == 1 ? 'name is' : 'names are'} #{said.call(closest)}." unless closest.empty?
        return "The game has no variables of its own." if own.empty?

        more = own.size - NAMES_LISTED_MOST
        "Its variables are #{said.call(own.first(NAMES_LISTED_MOST))}#{" and #{more} more" if more.positive?}."
      end

      # The program, refused in plain words where there is none to say +what+.
      def named_program(what)
        read_program or refuse_no_program!(what)
      end

      # A reader with no program can name nothing but its variables.
      def refuse_no_program!(what)
        raise ArgumentError, "This run played no whole program, so nothing says #{what}. Run a program " \
                             "(`VBlank.game`, or `program(...)`) to read #{what} by name."
      end
    end
  end
end
