# frozen_string_literal: true

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
      def var(name) = read_program ? read_program.var_in_game_units(name, raw_var(name)) : raw_var(name)
      def [](name) = var(name)

      # A sprite by its name (`sprite :walker2, image: :walker`): an IR::SpriteState with its +x+,
      # +y+, whether it is #shown?, the +pose+ it is showing, its +angle+ and its +scale+.
      def sprite(name) = named_program("its sprites").sprite_state(name, self)

      # A background by its name: an IR::BackgroundState with how far it is scrolled and the +map+
      # the game has set showing.
      def background(name) = named_program("its backgrounds").background_state(name, self)

      # The music's loudness, 0 to 100, as the game's own `music_volume` reads it.
      def music_volume = named_program("its music").music_volume_from(self)

      private

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
