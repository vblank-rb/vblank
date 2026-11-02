# frozen_string_literal: true

module VBlank
  module IR
    # The button vocabulary: the set of button names a program may read with
    # `held` / `pressed`. This is a cross-backend contract, not a backend detail,
    # so it lives in the IR core next to Int32 — every backend agrees on the SAME
    # names, then maps each to its own world (a hardware key bit on the console, a
    # set membership in the interpreter, a key event in a browser). The vocabulary
    # is shared; the mapping is per-backend.
    #
    # This mirrors how color works: the IR carries the name (:a, :red) and each
    # backend resolves it. Naming a button that isn't here is almost always a typo,
    # and one that would otherwise read as "never pressed" — so callers check
    # against this list and say so plainly.
    module Buttons
      # Every button of any console, by the names a program uses: the ten Game Boy Advance
      # buttons, then the two only a Super Nintendo controller has, then the one only a Sega Genesis
      # pad has (C: its B and C are the Advance's B and A's neighbours, and it has no Select). A new
      # button goes on the end, since the first ten keep the order the Advance's key register has
      # them in. Which a console has is its description's to say (Console::Description#buttons),
      # and the build refuses the rest.
      NAMES = %i[a b select start right left up down r l x y c].freeze

      # ANY BUTTON AT ALL, which is not a button and so is not in NAMES: `held(:any)` holds
      # while one of them is down, and `pressed(:any)` on a frame one of them went down —
      # including while another is still held, the same edge each button has on its own. It
      # is how a game leaves an attract screen.
      ANY = :any

      # THE SECOND PLAYER'S BUTTONS. A game asks with `held(:left, player: 2)`, and whoever plays
      # the game for it (a test, a tape) holds :p2_left. They are names of their own so that a
      # list of buttons held stays one plain list, whichever controller each is on, on its way
      # through every run to the console.
      SECOND_PLAYER = NAMES.to_h { |name| [name, :"p2_#{name}"] }.freeze

      # Every button a player can hold, on either controller.
      HOLDABLE = (NAMES + SECOND_PLAYER.values).freeze

      # In a mask, the second player's buttons sit this many bits above the first's.
      SECOND_PLAYER_SHIFT = 16

      module_function

      # Whether +name+ is a button a program can read.
      def known?(name)
        NAMES.include?(name)
      end

      # Whether `held` and `pressed` can ask about +name+: a button, or any of them.
      def readable?(name) = known?(name) || name == ANY

      # Whether a test or a tape can hold +name+: a button of either player.
      def holdable?(name) = HOLDABLE.include?(name)

      # Whether `held` and `pressed` can ask about +player+: the first, the second, or either.
      def player?(player) = [1, 2, ANY].include?(player)

      # The first player's buttons among +held+, and then the second's, by the plain names each
      # has on its own controller: what a console's two ports are told.
      def by_controller(held)
        first = held & NAMES
        [first, SECOND_PLAYER.select { |_name, theirs| held.include?(theirs) }.keys]
      end

      # Every name a test of +button+ for +player+ looks for among the buttons held: `pressed(:any,
      # player: 2)` is all of the second player's, and `held(:left, player: ANY)` is two.
      def names_asked(button, player)
        buttons = button == ANY ? NAMES : [button]
        first = player == 2 ? [] : buttons
        second = player == 1 ? [] : SECOND_PLAYER.values_at(*buttons)
        first + second
      end

      # +held+ buttons as one number, a bit each in the order NAMES lists them — for the first ten
      # the order the Advance's key register has them in, which the emulator's keys and the native
      # lowering's runtime both read — and the second player's the same, SECOND_PLAYER_SHIFT up.
      def mask(held) = Array(held).reduce(0) { |bits, button| bits | (1 << bit_of(button)) }

      def bit_of(button)
        NAMES.index(button) || (SECOND_PLAYER_SHIFT + SECOND_PLAYER.values.index(button))
      end
    end
  end
end
