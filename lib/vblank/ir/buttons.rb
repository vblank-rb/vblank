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
      # them in. Which a console has is its description's to list (Console::Description#buttons),
      # and the build refuses the rest.
      NAMES = %i[a b select start right left up down r l x y c].freeze

      # ANY BUTTON AT ALL, which is not a button and so is not in NAMES: `held(:any)` holds
      # while one of them is down, and `pressed(:any)` on a frame one of them went down —
      # including while another is still held, the same edge each button has on its own. It
      # is how a game leaves an attract screen.
      ANY = :any

      module_function

      # THE MOST PLAYERS ANY BUILD READS. A console seats fewer, by its controllers
      # (Console::Description#controllers), and refuses the rest at the build. A computer has no
      # ports to count, so this is the computer's ceiling, and it is ours to choose: it catches a
      # typo (`player: 100`), and it gives the buttons of one pass a largest size — sixteen
      # players of under sixteen buttons each is 32 bytes a pass, which a network can carry sixty
      # times a second when every machine runs the whole game from every player's buttons. It is
      # twice the eight players a party game wants. Raising it is this one number.
      MOST_PLAYERS = 16

      # THE OTHER PLAYERS' BUTTONS. A game asks with `held(:left, player: 3)`, and whoever plays the
      # game for it (a test, a tape) holds :p3_left. They are names of their own so that a list of
      # buttons held stays one plain list, whichever controller each is on, on its way through
      # every run to the console. The first player's are the plain names: one name for one button.
      def name_for(button, player) = player == 1 ? button : :"p#{player}_#{button}"

      # Each player's button names, the first player's first.
      PLAYERS_NAMES = (1..MOST_PLAYERS).map { |player| NAMES.map { |name| name_for(name, player) }.freeze }.freeze

      # The second player's button names by the button each is.
      SECOND_PLAYER = NAMES.zip(PLAYERS_NAMES[1]).to_h.freeze

      # Every button a player can hold, on any controller, in player order.
      HOLDABLE = PLAYERS_NAMES.flatten.freeze

      # Each name a test can hold, to the button and the player it is.
      HELD_NAMES = PLAYERS_NAMES.each.with_index(1).flat_map do |names, player|
        names.zip(NAMES).map { |name, button| [name, [button, player].freeze] }
      end.to_h.freeze

      # In one number for every player (#mask), each player's buttons sit this many bits above the
      # player before's.
      PLAYER_SHIFT = 16

      # Whether +name+ is a button a program can read.
      def known?(name)
        NAMES.include?(name)
      end

      # Whether `held` and `pressed` can ask about +name+: a button, or any of them.
      def readable?(name) = known?(name) || name == ANY

      # Whether a test or a tape can hold +name+: a button of any player.
      def holdable?(name) = HELD_NAMES.key?(name)

      # The player whose button +name+ is (1 for the plain names), and the button it is.
      def player_of(name) = HELD_NAMES.fetch(name).last
      def button_of(name) = HELD_NAMES.fetch(name).first

      # Whether `held` and `pressed` can ask about +player+: a player from 1 to MOST_PLAYERS, or
      # any of them.
      def player?(player) = player == ANY || (player.is_a?(Integer) && player.between?(1, MOST_PLAYERS))

      # The first player's buttons among +held+, and then the second's, by the plain names each
      # has on its own controller: what a console's two ports are told.
      def by_controller(held)
        first = held & NAMES
        [first, SECOND_PLAYER.select { |_name, theirs| held.include?(theirs) }.keys]
      end

      # Every name a test of +button+ for +player+ looks for among the buttons held: `pressed(:any,
      # player: 2)` is all of the second player's, and `held(:left, player: ANY)` is every player's
      # left. A player who is not connected holds nothing, so asking about every player is asking
      # about every connected one.
      def names_asked(button, player)
        buttons = button == ANY ? NAMES : [button]
        players = player == ANY ? (1..MOST_PLAYERS) : [player]
        players.flat_map { |each_player| buttons.map { |name| name_for(name, each_player) } }
      end

      # The highest player with a button among +held+, or 1 for none.
      def highest_player(held) = Array(held).map { |name| player_of(name) }.max || 1

      # THE BUTTONS OF ONE PASS, AS A COMPUTER'S RUNTIME READS THEM: one number per connected
      # player, the first player's first, a bit each in the order NAMES lists them. This plain
      # list is what a network will carry later, a list a pass.
      #
      # How many are connected: at least +connected+, which is how many the pass before had, and
      # at least the highest player holding a button now. So a player counts as connected from the
      # first time they hold a button, and letting go of every button is not unplugging. A caller
      # keeps the list's length and hands it back for the next pass.
      def masks(held, connected = 1)
        held = Array(held)
        Array.new([connected, highest_player(held)].max) { |index| player_mask(held, index + 1) }
      end

      # THE BUTTONS OF EACH PASS IN TURN, for whatever hands them to a computer's runtime a pass at
      # a time (a headless run, a live session): it keeps how many players are connected between
      # passes, so #masks's rule is kept in one place.
      class PassButtons
        def initialize = @connected = 1

        # +held+ as this pass's list (Buttons.masks).
        def masks(held) = Buttons.masks(held, @connected).tap { |list| @connected = list.length }

        # ...written as the headless programs read it: the numbers on one line, a space between.
        def headless_input_line(held) = masks(held).join(" ")
      end

      # +player+'s buttons among +held+ as one number, a bit each in NAMES's order.
      def player_mask(held, player)
        held.reduce(0) { |bits, name| player_of(name) == player ? bits | (1 << NAMES.index(button_of(name))) : bits }
      end

      # +held+ buttons as one number, a bit each in the order NAMES lists them — for the first ten
      # the order the Advance's key register has them in, which the emulator's keys read — and each
      # further player's the same, PLAYER_SHIFT up from the one before. Past the second player the
      # number is wider than a console's (Ruby's numbers have no width), which only a playthrough
      # reads, to hand the names on to a computer's run.
      def mask(held) = Array(held).reduce(0) { |bits, button| bits | (1 << bit_of(button)) }

      def bit_of(button)
        button, player = HELD_NAMES.fetch(button)
        (PLAYER_SHIFT * (player - 1)) + NAMES.index(button)
      end
    end
  end
end
