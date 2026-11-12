# frozen_string_literal: true

module VBlank
  module IR
    # THE KEYS AND GAMEPAD BUTTONS A GAME ADDS FOR A COMPUTER (Builder::Input#computer_keys and
    # #computer_gamepad). A build that plays on a computer (the desktop window, `vblank run`, the
    # web page) starts with VBlank's own layout — the arrows, X for A, Z for B, and the rest — and
    # these are added to it: more keys for a button, never a key moved. So a pinball game can have
    # D press A as well as X, while the right arrow stays Right for its menus.
    #
    # NO KEY PRESSES TWO BUTTONS. A key the layout already gives a button, or that the window keeps
    # for itself (pause, the menu, fast forward), is refused when the game is built, in plain words.
    # A key pressing two buttons would make a game's menus misread it, and a player who changes one
    # of the two in Controls could not tell which one they changed.
    #
    # A console's cartridge never reads this: its buttons are the console's own.
    #
    # Each runtime is handed the layout as one list of numbers (.runtime_numbers): how many entries, then
    # for each its button (its place in Buttons::NAMES), 0 for a key or 1 for a gamepad button, and
    # the key's USB number (which is SDL's scancode for it; the web page turns it into the browser's
    # name) or SDL's number for the gamepad button.
    module ComputerControls
      KEY = 0
      PAD = 1

      # The buttons a computer's window has keys for.
      BUTTONS = %i[a b select start right left up down r l].freeze

      # The most keys, and gamepad buttons, one button has in a window (rg_window.h's
      # RG_WINDOW_KEYS_A_BUTTON and RG_WINDOW_PADS_A_BUTTON).
      MOST_KEYS = 2
      MOST_PADS = 2

      # The keys a game can name, by the USB number each runtime reads them by. Letters are :a to
      # :z, digits 0 to 9.
      LETTER_KEYS = ("a".."z").each_with_index.to_h { |letter, at| [letter.to_sym, 4 + at] }.freeze
      DIGIT_KEYS = { 1 => 30, 2 => 31, 3 => 32, 4 => 33, 5 => 34, 6 => 35, 7 => 36, 8 => 37, 9 => 38, 0 => 39 }.freeze
      OTHER_KEYS = { enter: 40, escape: 41, backspace: 42, tab: 43, space: 44, minus: 45, equals: 46, left_bracket: 47,
                     right_bracket: 48, backslash: 49, semicolon: 51, quote: 52, backquote: 53, comma: 54, period: 55,
                     slash: 56, right: 79, left: 80, down: 81, up: 82, left_ctrl: 224, left_shift: 225, left_alt: 226,
                     right_ctrl: 228, right_shift: 229, right_alt: 230 }.freeze
      KEYS = LETTER_KEYS.merge(DIGIT_KEYS).merge(OTHER_KEYS).freeze

      # VBlank's own layout: the keys each button starts on (the window's, rg_window.c's
      # button_kinds; the page's, rg_page.js's PAGE_KEYS).
      LAYOUT_KEYS = Ractor.make_shareable({ a: %i[x], b: %i[z], select: %i[backspace right_shift], start: %i[enter], right: %i[right],
                      left: %i[left], up: %i[up], down: %i[down], r: %i[s], l: %i[a] })

      # Player 2's keys, on the keyboard's right hand, for a game two people play at one keyboard:
      # I J K L the pad, O for A and U for B (A on the right, as the console has it), 7 and 9 the
      # shoulders and 8 and 0 Select and Start, above them. They are away from player 1's (the
      # arrows, and Z X A S on the left) and from the window's own keys. Each window reads them
      # the same (rg_seats.h, Live::Seats, rg_page.js's PAGE_SECOND_PLAYER_KEYS), only in a game
      # whose `players:` seats two or more, and only where nobody else has the key. Players 3 and 4 are gamepads only: four people do not fit round one
      # keyboard, and most keyboards lose keys when that many are held at once.
      SECOND_PLAYER_KEYS = Ractor.make_shareable({ o: :a, u: :b, 8 => :select, 0 => :start, l: :right, j: :left,
                                                   i: :up, k: :down, 9 => :r, 7 => :l })

      # The keys the window keeps for itself, and what for: no button can have one. The desktop
      # window's hotkeys, the web page's (F for fullscreen), Escape, which stops choosing a key, and
      # the key above Tab, which opens the menu.
      WINDOW_KEYS = Ractor.make_shareable({ p: "Pause", n: "Step one frame", m: "Mute", f: "Fullscreen on a web page", tab: "Fast forward",
                      escape: "giving up choosing a key", backquote: "the menu" })

      # A gamepad's buttons, by SDL's number for each.
      PADS = { south: 0, east: 1, west: 2, north: 3, back: 4, guide: 5, start: 6, left_stick: 7, right_stick: 8,
               left_shoulder: 9, right_shoulder: 10, dpad_up: 11, dpad_down: 12, dpad_left: 13, dpad_right: 14 }.freeze

      # The gamepad buttons no button has in VBlank's layout, on the desktop or on a web page (whose
      # face buttons are the other way round), and which open no menu.
      FREE_PADS = %i[west north left_stick right_stick].freeze

      # How many gamepad buttons each button starts with.
      LAYOUT_PADS = 1

      # The entries for +given+ (button => key name, or a list of them), as [button, :key, name]
      # triples, or a friendly error naming what cannot be. +most_players+ is the most players the
      # build seats: a game for two or more keeps player 2's keys free.
      def self.keys_entries!(given, most_players: nil)
        entries = entries_of(given, :computer_keys)
        refuse_same_twice!(entries, :computer_keys)
        entries.each { |button, name| refuse_key!(button, name) }
        entries.each { |button, name| refuse_second_player_key!(button, name) } if most_players && most_players > 1
        refuse_crowded!(entries, :computer_keys, "keys", most: MOST_KEYS) { |button| LAYOUT_KEYS.fetch(button).length }
        entries.map { |button, name| [button, :key, name] }
      end

      # ...and for gamepad buttons.
      def self.pads_entries!(given)
        entries = entries_of(given, :computer_gamepad)
        refuse_same_twice!(entries, :computer_gamepad)
        entries.each { |button, name| refuse_pad!(button, name) }
        refuse_crowded!(entries, :computer_gamepad, "gamepad buttons", most: MOST_PADS) { LAYOUT_PADS }
        entries.map { |button, name| [button, :pad, name] }
      end

      # The list of numbers each runtime reads, for a program's entries (nil for none): how many,
      # then a button, KEY or PAD, and the key's or gamepad button's number for each.
      def self.runtime_numbers(entries)
        list = Array(entries)
        [list.length, *list.flat_map do |button, kind, name|
          kind == :key ? [BUTTONS.index(button), KEY, KEYS.fetch(name)] : [BUTTONS.index(button), PAD, PADS.fetch(name)]
        end]
      end

      def self.entries_of(given, verb)
        given.flat_map do |button, names|
          refuse_button!(button, verb)
          Array(names).map { |name| [button, name] }
        end
      end

      def self.refuse_button!(button, verb)
        return if BUTTONS.include?(button)

        raise ArgumentError, "`#{verb} #{button}:` names no button a computer's window has. " \
                             "To fix this, use one of these: #{BUTTONS.map { |each| ":#{each}" }.join(' ')}."
      end

      def self.refuse_same_twice!(entries, verb)
        entries.group_by(&:last).each do |name, uses|
          next if uses.length == 1

          raise ArgumentError, "`#{verb}` gives #{name.inspect} to #{uses.map { |button, _| ":#{button}" }.join(' and ')}. " \
                               "One key or gamepad button presses one button. To fix this, give it to one of them."
        end
      end

      def self.refuse_key!(button, name)
        unless KEYS.key?(name)
          raise ArgumentError, "`computer_keys #{button}: #{name.inspect}` names no key VBlank knows. To fix this, use a letter " \
                               "(:d), a digit (1), or one of these: #{OTHER_KEYS.keys.map { |key| ":#{key}" }.join(' ')}."
        end
        if (reason = WINDOW_KEYS[name])
          raise ArgumentError, "`computer_keys #{button}: #{name.inspect}` names a key the window keeps for itself " \
                               "(#{reason}). To fix this, choose another key."
        end
        owner = LAYOUT_KEYS.find { |_, keys| keys.include?(name) }&.first
        return unless owner

        raise ArgumentError, "`computer_keys #{button}: #{name.inspect}` names a key that already presses :#{owner} on a " \
                             "computer. A key presses one button, and :#{owner} must keep its key. To fix this, choose a " \
                             "key no button has, for example :d or :space."
      end

      def self.refuse_second_player_key!(button, name)
        theirs = SECOND_PLAYER_KEYS[name]
        return unless theirs

        raise ArgumentError, "`computer_keys #{button}: #{name.inspect}` names a key that presses player 2's :#{theirs} on a " \
                             "computer. This game is for more than one player, and player 2 must keep the key. To fix " \
                             "this, choose a key no button has, for example :d or :space."
      end

      def self.refuse_pad!(button, name)
        return if FREE_PADS.include?(name)

        why = PADS.key?(name) ? "is a button the window already uses. A gamepad button presses one button" : "names no gamepad button"
        raise ArgumentError, "`computer_gamepad #{button}: #{name.inspect}` #{why}. " \
                             "To fix this, use one of these: #{FREE_PADS.map { |pad| ":#{pad}" }.join(' ')}."
      end

      # A button given more than the window has room for (+most+), counting the ones it starts with.
      def self.refuse_crowded!(entries, verb, what, most:)
        entries.group_by(&:first).each do |button, added|
          has = yield(button)
          next if has + added.length <= most

          fix = most > has ? "give :#{button} at most #{most - has}" : "give them to another button"
          raise ArgumentError, "`#{verb}` gives :#{button} #{added.length} more #{what}, and it has #{has} already. " \
                               "A button has room for #{most} #{what} on a computer. To fix this, #{fix}."
        end
      end

      private_class_method :entries_of, :refuse_button!, :refuse_same_twice!, :refuse_key!, :refuse_second_player_key!,
                           :refuse_pad!, :refuse_crowded!
    end
  end
end
