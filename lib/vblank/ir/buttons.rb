# frozen_string_literal: true

module VBlank
  module IR
    # The button vocabulary: the set of button names a program may read with
    # `held` / `pressed`. This is a cross-backend contract, not a backend detail,
    # so it lives in the IR core next to Int32 — every backend agrees on the same
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
      # pad has (C: its B and C are the Advance's B and A's neighbours, and it has no Select), then the
      # two only a PlayStation pad has, its second shoulder buttons, L2 and R2. A new button goes on
      # the end, since the first ten keep the order the Advance's key register has them in. Which a
      # console has is its description's to list (Console::Description#buttons), and the build
      # refuses the rest.
      NAMES = %i[a b select start right left up down r l x y c l2 r2].freeze

      # Other names for some of the buttons, which a game for one console can use as its pad names
      # them: a PlayStation pad's shapes and first shoulder buttons. Each is the same button as the
      # shared name: `held(:cross)` is `held(:a)`, on any console.
      OTHER_NAMES = Ractor.make_shareable({ cross: :a, circle: :b, triangle: :x, square: :y, l1: :l, r1: :r })

      # Any button at all, which is not a button and so is not in NAMES: `held(:any)` holds
      # while one of them is down, and `pressed(:any)` on a frame one of them went down —
      # including while another is still held, the same edge each button has on its own. It
      # is how a game leaves an attract screen.
      ANY = :any

      module_function

      # The most players any build reads. A console seats fewer, by its controllers
      # (Console::Description#controllers), and refuses the rest at the build. A computer has no
      # ports to count, so this is the computer's ceiling, and it is ours to choose: it catches a
      # typo (`player: 100`), and it gives the buttons of one pass a largest size — sixteen
      # players of under sixteen buttons each is 32 bytes a pass, which a network can carry sixty
      # times a second when every machine runs the whole game from every player's buttons. It is
      # twice the eight players a party game wants. Raising it is this one number.
      MOST_PLAYERS = 16

      # The other players' buttons. A game asks with `held(:left, player: 3)`, and whoever plays the
      # game for it (a test, a tape) holds :p3_left. They are names of their own so that a list of
      # buttons held stays one plain list, whichever controller each is on, on its way through
      # every run to the console. The first player's are the plain names: one name for one button.
      def name_for(button, player) = player == 1 ? button : :"p#{player}_#{button}"

      # Each player's button names, the first player's first.
      PLAYERS_NAMES = (1..MOST_PLAYERS).map { |player| NAMES.map { |name| name_for(name, player) }.freeze }.freeze

      # Every button a player can hold, on any controller, in player order.
      HOLDABLE = PLAYERS_NAMES.flatten.freeze

      # Each name a test can hold, to the button and the player it is.
      HELD_NAMES = PLAYERS_NAMES.each.with_index(1).flat_map do |names, player|
        names.zip(NAMES).map { |name, button| [name, [button, player].freeze] }
      end.to_h.freeze

      # In one number for every player (#mask), each player's buttons sit this many bits above the
      # player before's.
      PLAYER_SHIFT = 16

      # Every button of one player set, a bit each in NAMES's order: what a computer's runtime keeps
      # of a player's number (Computer::ConsoleNumbers writes it ahead of each runtime), so a button
      # added to NAMES is kept there too.
      EVERY_BUTTON_MASK = (1 << NAMES.length) - 1

      # How far a button is pulled (`pulled(:r2)`), in percent: 0 let go, FULL_PULL all the way.
      # A button that is only up or down, which is every button a console's pad has, is 0 or
      # FULL_PULL. A gamepad's triggers on a computer can be part pulled, and so can a button a
      # test holds part pulled (#held_names).
      FULL_PULL = 100

      # The buttons a computer's runtime can be told a part pull of: a gamepad's two triggers.
      PULLED_BUTTONS = %i[l2 r2].freeze

      # How far a part-pulled button must be pulled to count as held, in percent: the same in every
      # window and in a test, so `held(:l2)` and `pulled(:l2)` agree everywhere. It is XInput's
      # trigger threshold, XINPUT_GAMEPAD_TRIGGER_THRESHOLD, 30 of 255 (Microsoft's XInput
      # documentation, XINPUT_GAMEPAD), rounded up to a whole percent.
      HELD_FROM = 12

      # In a player's number (#player_mask), each of PULLED_BUTTONS has PULL_BITS bits for how far
      # it is pulled, the first from PULL_SHIFT up, above the buttons' own bits. Nought there means
      # "as held": FULL_PULL while the button is held and 0 when not, so a key, or anything that
      # keeps only the buttons' bits, reads all or nothing.
      PULL_SHIFT = 16
      PULL_BITS = 7

      # The bit a part pull of +button+ (one of PULLED_BUTTONS) starts at in a player's number.
      def pull_shift(button) = PULL_SHIFT + (PULL_BITS * PULLED_BUTTONS.index(button))

      # The names in a list of buttons held, which may hold part pulls besides plain names: a Hash
      # of a name and how far it is pulled, in percent (`[:a, { l2: 40 }]`). A part pull is held
      # from HELD_FROM.
      def held_names(held)
        Array(held).flat_map { |entry| entry.is_a?(Hash) ? entry.filter_map { |name, pull| name if pull >= HELD_FROM } : [entry] }
      end

      # The part pulls in a list of buttons held, by name: what a Hash in it gives, each a whole
      # number from 0 to FULL_PULL, or a friendly error. Where more than one thing pulls a button (a
      # key and a gamepad, two gamepads of one player), the furthest is kept, and a button held as
      # a plain name, as a key holds it, is pulled all the way. Every window keeps the same rule.
      def pulls(held)
        given = Array(held).grep(Hash).each_with_object({}) do |pulls, furthest|
          pulls.each do |name, pull|
            refuse_pull!(name, pull)
            furthest[name] = [furthest.fetch(name, 0), pull].max
          end
        end
        Array(held).each { |name| given[name] = FULL_PULL if name.is_a?(Symbol) && given.key?(name) }
        given
      end

      def refuse_pull!(name, pull)
        return if pull.is_a?(Integer) && pull.between?(0, FULL_PULL)

        raise ArgumentError, "#{name.inspect} is held #{pull.inspect} of the way. To fix this, give a whole number " \
                             "from 0 (let go) to #{FULL_PULL} (pulled all the way)."
      end
      private_class_method :refuse_pull!

      # How far +button+ of +player+ is pulled, in percent, among +held+ (a list of buttons held,
      # part pulls among them): the furthest part pull given (#pulls), else FULL_PULL while it is
      # held and 0 when it is not.
      def pull_among(held, button, player)
        name = name_for(button, player)
        pulls(held).fetch(name) { held_names(held).include?(name) ? FULL_PULL : 0 }
      end

      # Several players' numbers (#player_mask) made one, as a machine of a match sends all its own
      # players as its one: every button held in any, and each trigger's furthest pull, rather than
      # the bits of two pulls run together.
      def merged_number(numbers)
        buttons = numbers.reduce(0) { |bits, number| bits | (number & EVERY_BUTTON_MASK) }
        field = (1 << PULL_BITS) - 1
        PULLED_BUTTONS.reduce(buttons) do |bits, button|
          shift = pull_shift(button)
          bits | (numbers.map { |number| (number >> shift) & field }.max.to_i << shift)
        end
      end

      # Whether +name+ is a button a program can read.
      def known?(name)
        NAMES.include?(name)
      end

      # Whether `held` and `pressed` can ask about +name+: a button, by its name or another
      # (OTHER_NAMES), or any of them.
      def readable?(name) = known?(name) || OTHER_NAMES.key?(name) || name == ANY

      # The button +name+ is, by the name in NAMES: +name+ itself, or the button one of OTHER_NAMES is.
      def named(name) = OTHER_NAMES.fetch(name, name)

      # Whether a test or a tape can hold +name+: a button of any player.
      def holdable?(name) = HELD_NAMES.key?(name)

      # The player whose button +name+ is (1 for the plain names), and the button it is.
      def player_of(name) = HELD_NAMES.fetch(name).last
      def button_of(name) = HELD_NAMES.fetch(name).first

      # Whether `held` and `pressed` can ask about +player+: a player from 1 to MOST_PLAYERS, or
      # any of them.
      def player?(player) = player == ANY || (player.is_a?(Integer) && player.between?(1, MOST_PLAYERS))

      # The first player's buttons among +held+, then the second's, and so on for +controllers+
      # players, by the plain names each has on its own controller: what a console's ports are told.
      def by_controller(held, controllers: 2)
        held = held_names(held)
        PLAYERS_NAMES.first(controllers).map do |names|
          NAMES.zip(names).filter_map { |name, theirs| name if held.include?(theirs) }
        end
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

      # The highest player with a button among +held+, or 1 for none. A button pulled any way at all
      # counts, so a player whose trigger is only touched is handed the pull.
      def highest_player(held)
        touched = held_names(held) + pulls(held).filter_map { |name, pull| name if pull.positive? }
        touched.map { |name| player_of(name) }.max || 1
      end

      # The buttons of one pass, as a computer's runtime reads them: one number per connected
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

      # The buttons of each pass in turn, for whatever hands them to a computer's runtime a pass at
      # a time (a headless run, a live session): it keeps how many players are connected between
      # passes, so #masks's rule is kept in one place.
      class PassButtons
        def initialize = @connected = 1

        # +held+ as this pass's list (Buttons.masks).
        def masks(held) = Buttons.masks(held, @connected).tap { |list| @connected = list.length }

        # ...written as the headless programs read it: the numbers on one line, a space between.
        def headless_input_line(held) = masks(held).join(" ")
      end

      # +player+'s buttons among +held+ as one number, a bit each in NAMES's order, and above them how
      # far each of PULLED_BUTTONS is part pulled, where +held+ gives a part pull (#pull_shift).
      def player_mask(held, player)
        buttons = held_names(held).reduce(0) do |bits, name|
          player_of(name) == player ? bits | (1 << NAMES.index(button_of(name))) : bits
        end
        given = pulls(held)
        PULLED_BUTTONS.reduce(buttons) { |bits, button| bits | (given.fetch(name_for(button, player), 0) << pull_shift(button)) }
      end

      # +held+ buttons as one number, a bit each in the order NAMES lists them — for the first ten
      # the order the Advance's key register has them in, which the emulator's keys read — and each
      # further player's the same, PLAYER_SHIFT up from the one before. Past the second player the
      # number is wider than a console's (Ruby's numbers have no width), which only a playthrough
      # reads, to hand the names on to a computer's run.
      def mask(held) = held_names(held).reduce(0) { |bits, button| bits | (1 << bit_of(button)) }

      def bit_of(button)
        button, player = HELD_NAMES.fetch(button)
        (PLAYER_SHIFT * (player - 1)) + NAMES.index(button)
      end
    end
  end
end
