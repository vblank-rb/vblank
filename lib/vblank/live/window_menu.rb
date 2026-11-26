# frozen_string_literal: true

module VBlank
  module Live
    # The menu over the window a game is played in, written down once: what it holds, the keys and
    # gamepad buttons that work it, and how it looks. vblank run draws it (Menu says how it
    # behaves, SDL draws it), and so do the desktop build, which is handed all of this as C data
    # (IR::Backends::Native::MenuData), and the web page, handed it as JavaScript data
    # (IR::Backends::JS::MenuData). A line added here becomes a line in each. Cartridges have none.
    #
    # It is a dark menu bar: a bar along the top with a heading for each part, the open heading's
    # lines in a box under it, a slider for a number and a check mark for a setting that is on.
    # It is drawn over the game's picture in the
    # window's own pixels, not the game's, so its letters are sharp on any screen.
    module WindowMenu
      # What the window does, as a player last left it. The starting values are the desktop build's
      # (rg_window.c), the frame rate shown among them.
      Settings = Data.define(:fast_forward_speed, :scale, :fullscreen, :volume, :muted, :frame_rate, :frame_time) do
        # One setting by its name, as a line of the menu names the setting it moves.
        def setting(name) = to_h.fetch(name)
      end
      STARTING = Settings.new(fast_forward_speed: 4, scale: 3, fullscreen: false, volume: 100, muted: false,
                              frame_rate: true, frame_time: false)

      # A save or load: +action+ is :save or :load, and +slot+ is QUICK_SLOT or one of STATE_SLOTS.
      StateRequest = Data.define(:action, :slot)

      # A match asked for under the Match heading: +does+ is what its line does (MATCH_LINES), +text+
      # the address or room code typed for a join (nil for a host), and +players+ how many a host waits
      # for (nil for a join, where the host decides).
      MatchRequest = Data.define(:does, :text, :players)

      # A heading on the bar and the lines under it. A heading of states is one a window offers
      # only where states can be kept: not in a match with other players.
      Heading = Data.define(:name, :lines) do
        def states? = lines.any?(&:state?)
      end

      # A line under a heading: its +label+, and what it is.
      # - :action does what +does+ names (:resume, :quit, :variables) when it is chosen with Enter;
      #   :variables opens the window of the game's variables, or shuts it, and closes the menu.
      # - :slider holds a number of +setting+'s within +range+, changed +step+ at a time with left
      #   and right, and written as +written+ names: :times ("4x"), :percent ("90%"), or :window
      #   ("3x  (720 × 480)", the size the window is then).
      # - :check holds +setting+ on or off, switched with Enter.
      # - :button and :hotkey show what number +place+ among the console's buttons or the window's
      #   hotkeys is on now, and Enter waits for the next key or gamepad button pressed to change it.
      # - :state saves or loads a state: Enter asks for the StateRequest in +request+ (its action and its
      #   slot, which is also +place+: 0 for the quick state, 1 to 10 for the others). A line with a
      #   +shortcut+ shows that at its right; one without shows whether the slot holds a state, and when
      #   it was taken.
      # - :match asks for a match (a MatchRequest doing +does+): at once for a host, and for a join once
      #   what +asks+ names (:address or :code) is typed on the line and Enter pressed.
      # +shortcut+ is the key that does the same outside the menu, written dim at the right.
      # +line_before+ draws a line across the box above it, to set it apart.
      # A slider's +written+ is :count too, the number alone ("4"), and its +setting+ may be one the
      # menu keeps for itself rather than a Settings one (Menu::OWN_SETTINGS).
      Line = Data.define(:label, :kind, :does, :setting, :range, :step, :written, :shortcut, :line_before, :place, :request,
                         :asks) do
        def self.action(label, does, shortcut: nil, line_before: false)
          new(label, :action, does, nil, nil, nil, nil, shortcut, line_before, 0, nil, nil)
        end

        def self.slider(label, setting, range, step, written)
          new(label, :slider, nil, setting, range, step, written, nil, false, 0, nil, nil)
        end

        def self.check(label, setting, shortcut: nil) = new(label, :check, nil, setting, nil, nil, nil, shortcut, false, 0, nil, nil)
        def self.button(label, place) = new(label, :button, nil, nil, nil, nil, nil, nil, false, place, nil, nil)
        def self.hotkey(label, place) = new(label, :hotkey, nil, nil, nil, nil, nil, nil, false, place, nil, nil)

        def self.state(label, action, slot, shortcut: nil)
          new(label, :state, nil, nil, nil, nil, nil, shortcut, false, slot, StateRequest.new(action: action, slot: slot), nil)
        end

        def self.match(label, does, asks: nil) = new(label, :match, does, nil, nil, nil, nil, nil, false, 0, nil, asks)

        # Whether the line saves or loads a state.
        def state? = kind == :state
      end

      # The places a state can be kept besides the quick one: 1 to 10. The quick one is place 0.
      STATE_SLOTS = (1..10)
      QUICK_SLOT = 0

      # The keys that save and load the quick state outside the menu, as emulators have them. They are
      # fixed: the hotkeys are the keys a player can change.
      QUICK_SAVE_KEY = "F5"
      QUICK_LOAD_KEY = "F9"

      # The console's buttons and the window's hotkeys, in Settings::BUTTONS's and HOTKEYS's order.
      BUTTON_NAMES = %w[A B Select Start Right Left Up Down R L X Y C L2 R2].freeze
      HOTKEY_NAMES = ["Pause", "Step one frame", "Show frame rate", "Fullscreen", "Mute", "Show menu", "Fast forward"].freeze

      # The most times the picture's size a window can be made. A frontend may set fewer: the most
      # that fits on the screen it is on.
      SCALES = (1..10)

      # The heading of what a game's author reads as it plays.
      DEVELOPER = "Developer"

      HEADINGS = Ractor.make_shareable([
        Heading.new("Game", [Line.action("Resume", :resume, shortcut: "F1"),
                             Line.slider("Fast forward", :fast_forward_speed, 2..8, 1, :times),
                             Line.action("Quit", :quit, shortcut: "Esc", line_before: true)]),
        Heading.new("Window", [Line.slider("Size", :scale, SCALES, 1, :window), Line.check("Fullscreen", :fullscreen),
                               Line.check("Show frame rate", :frame_rate)]),
        Heading.new("Sound", [Line.slider("Volume", :volume, 0..100, 10, :percent), Line.check("Mute", :muted)]),
        Heading.new("Keys", [*BUTTON_NAMES.each_with_index.map { |name, place| Line.button(name, place) },
                             Line.action("Reset", :reset_keys, line_before: true)]),
        Heading.new("Hotkeys", [*HOTKEY_NAMES.each_with_index.map { |name, place| Line.hotkey(name, place) },
                                Line.action("Reset", :reset_hotkeys, line_before: true)]),
        Heading.new("Save", [Line.state("Quick Save", :save, QUICK_SLOT, shortcut: QUICK_SAVE_KEY),
                             *STATE_SLOTS.map { |slot| Line.state("Slot #{slot}", :save, slot) }]),
        Heading.new("Load", [Line.state("Quick Load", :load, QUICK_SLOT, shortcut: QUICK_LOAD_KEY),
                             *STATE_SLOTS.map { |slot| Line.state("Slot #{slot}", :load, slot) }]),
        Heading.new(DEVELOPER, [Line.action("Game variables", :variables), Line.check("Show frame time", :frame_time)])
      ])

      # The heading that starts a match with players on other computers, which a window shows over a game
      # for several players when it can play one (Menu#match_players=), and never inside a match. The
      # game sees none of it: the match starts the game again, every player's at once, and the game
      # sees only its players arriving. A host waits for as many players as Players says, from two to
      # the most the game takes; MATCH_PLAYERS is the most any game takes.
      #
      # "By address" is a direct connection: the host's computer listens, and the others type its
      # address (Network::DirectPlay). "With a room code" meets on the relay (Network::RelayPlay): the
      # host is told a code, and the others type it.
      MATCH = "Match"
      MATCH_PLAYERS = (2..16)
      MATCH_HEADING = Ractor.make_shareable(
        Heading.new(MATCH, [Line.slider("Players", :match_players, MATCH_PLAYERS, 1, :count),
                            Line.match("Host by address", :host),
                            Line.match("Host with a room code", :host_code),
                            Line.match("Join by address", :join_address, asks: :address),
                            Line.match("Join by room code", :join_code, asks: :code)])
      )

      # The most characters typed for an address or a room code.
      TYPED_MOST = 64

      # The keys an address has besides letters and digits, by SDL's scancodes: the full stop, and the
      # key with the semicolon on it, which types the colon before the port (an address has no
      # semicolon, and the colon needs Shift).
      PERIOD_KEY = 55
      SEMICOLON_KEY = 51
      MINUS_KEY = 45

      # What is wrong with +text+ typed as an address, in words for the player, or nil when it is one: a
      # host, then a colon and a port from 1 to 65535 if it has one. Network::DirectPlay::Address.parse
      # holds the same rule; the menu checks it here, where the network is not loaded, so a typo is said
      # on the line rather than ending the game.
      def self.address_problem(text)
        host, port = text.split(":", 2)
        return nil if !host.to_s.empty? && (port.nil? || (port.match?(/\A\d+\z/) && port.to_i.between?(1, 65_535)))

        "Write the address as HOST:PORT, for example 192.168.1.5:7777."
      end

      # The character key +key+ types for what a match line +asks+: an address takes letters, digits,
      # dots, a colon and hyphens; a room code takes letters, in capitals, and digits. Nil for a key that
      # types none there.
      def self.typed_for_match(key, asks)
        typed = case key
                when PERIOD_KEY then "."
                when SEMICOLON_KEY then ":"
                when MINUS_KEY then "-"
                when LETTER_KEYS, DIGIT_KEYS then typed_letter(key)
                end
        return typed if asks == :address

        typed&.upcase if typed&.match?(/\A[a-z0-9]\z/)
      end

      # The window of the game's variables, which Developer, Game variables opens over the game as it
      # plays: a line for each variable and its value, VARIABLE_ROWS at a time under a heading that
      # stays put, scrolled with up and down. Letters typed find the variables whose names have them
      # (Backspace takes the last one off), up to FILTER_MOST of them. While it is open the keys that
      # type a name are the window's and not the game's.
      VARIABLE_ROWS = 12
      FILTER_MOST = 31
      # The widest number a variable holds, which the column of values has room for.
      WIDEST_VALUE = "-2147483648"
      # The keys that type a name, by SDL's scancodes, which name where a key sits: A to Z, 1 to 9
      # and 0, and the key with the minus on it, for the underscore names are written with.
      BACKSPACE_KEY = 42
      LETTER_KEYS = (4..29)
      DIGIT_KEYS = (30..39)
      UNDERSCORE_KEY = 45

      # The letter key +key+ types into the filter, or nil for a key that types none.
      def self.typed_letter(key)
        return (key - LETTER_KEYS.min + "a".ord).chr if LETTER_KEYS.cover?(key)
        return ((key - DIGIT_KEYS.min + 1) % 10).to_s if DIGIT_KEYS.cover?(key)

        "_" if key == UNDERSCORE_KEY
      end

      # The buttons of a window told no console: the Advance's, IR::Buttons::NAMES's first ten. It
      # is not read from Console::ADVANCE, since a game written out as Ruby carries this file and not
      # the consoles; test_menu.rb holds the two alike.
      ADVANCE_BUTTONS = IR::Buttons::NAMES.first(10).freeze

      # The headings a window shows: Keys has a line for each of the console's +buttons+ (by their
      # names in IR::Buttons::NAMES), so a Genesis game's window lists C and no Select, and +states+
      # false leaves out Save and Load. +match+ true puts MATCH_HEADING after Game. A line keeps its
      # +place+ among every button's.
      def self.headings(states: true, buttons: ADVANCE_BUTTONS, match: false)
        shown = states ? HEADINGS : HEADINGS.reject(&:states?)
        shown = [shown.first, MATCH_HEADING, *shown.drop(1)] if match
        shown.map do |heading|
          lines = heading.lines.select { |line| line.kind != :button || buttons.include?(IR::Buttons::NAMES.fetch(line.place)) }
          lines.length == heading.lines.length ? heading : heading.with(lines: lines)
        end
      end

      # The keys, by name; each frontend knows which of its own keys and buttons each name is. F1
      # opens and closes the menu, as in the desktop build, and so does the key above Tab, which a
      # Mac keyboard can press without holding fn. On a gamepad, the guide button in the middle
      # does, or Back and Start pressed together (a Mac may keep the guide button for its own use).
      # The arrows or the D-pad move; Enter or the gamepad's A does what a line says; the gamepad's
      # B closes the menu.
      OPEN_KEYS = %i[f1 grave].freeze
      OPEN_PAD = %i[guide].freeze
      OPEN_PAD_TOGETHER = %i[back start].freeze
      MOVE_KEYS = { up: :up, down: :down, left: :left, right: :right, enter: :enter }.freeze
      MOVE_PAD = { dpad_up: :up, dpad_down: :down, dpad_left: :left, dpad_right: :right, a: :enter, b: :close }.freeze

      # The look: sizes in points, which a frontend makes pixels by the screen's density, and colours
      # as red, green, blue and opacity, 0 to 255 each.
      SIZES = Ractor.make_shareable(
        { bar: 22, row: 22, pad: 8, heading_gap: 14, heading_pad: 4, least_width: 200, label_gap: 30, slider: 140,
          grab: 10, check: 14, corner: 4, frame_corner: 3, line_before: 9, status_gap: 8, status_pad: 8, status_line: 19,
          variables_width: 260, message_width: 520, message_gap: 12 }
      )
      COLORS = Ractor.make_shareable(
        { text: [255, 255, 255, 255], dim: [128, 128, 128, 255], bar: [36, 36, 36, 255], box: [20, 20, 20, 240],
          border: [110, 110, 128, 128], chosen: [66, 150, 250, 204], open: [66, 150, 250, 79],
          frame: [41, 74, 122, 138], grab: [61, 133, 224, 255], status: [15, 15, 15, 140],
          paused: [255, 204, 77, 255], fast: [128, 230, 255, 255] }
      )

      # What a frontend draws, in the window's own pixels, from the top left: boxes with round
      # corners of +radius+, and words, each letter copied from the font's picture
      # (Graphics::MenuFont) as +letters+ gives, in +color+.
      Box = Data.define(:x, :y, :width, :height, :radius, :color)
      Words = Data.define(:text, :color, :letters)
    end
  end
end
