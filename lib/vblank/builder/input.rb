# frozen_string_literal: true

module VBlank
  class Builder
    # The input verbs: turn a button into a {Condition} — held / pressed — to branch
    # with `if` and join with `&&` / `||`. Button names are validated against the shared
    # IR vocabulary. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    module Input
      # The words a game once gated a block on a button with, kept private so that the refusal
      # reaches a line in a game block, where it needs no receiver, and names the `if` to write.
      %i[held pressed].each do |test|
        class_eval <<~REFUSAL, __FILE__, __LINE__ + 1
          def if_#{test}(button = nil, player: 1, **, &)
            raise DSL::PlainRuby::Refused, button_test_message(:#{test}, button, player)
          end
          private :if_#{test}
        REFUSAL
      end

      # A {Condition} that holds while a button is down — branch on it with
      # `if held(:up)`, or `if held(:up, player: 2)` for the second controller.
      #
      # @param button [Symbol] button name
      # @param player [Integer, Symbol] whose controller: 1, 2, or :any for either
      def held(button, player: 1)
        reject_block!(:held, button) if block_given?
        check_button!(button)
        check_player!(player)
        DSL::Condition.new(self, Build.held(button, player: player))
      end

      # A {Condition} true on the frame a button is first pressed (edge-detected).
      #
      # @param button [Symbol] button name
      # @param player [Integer, Symbol] whose controller: 1, 2, or :any for either
      def pressed(button, player: 1)
        reject_block!(:pressed, button) if block_given?
        check_button!(button)
        check_player!(player)
        DSL::Condition.new(self, Build.pressed(button, player: player))
      end

      # HOW MANY PLAYERS ARE CONNECTED NOW, as a {DSL::Value}: at least 1. A player counts from
      # the first time one of their buttons is down, and stays counted. Ask it before reading a
      # player's buttons, so a game never waits on a player who is not there:
      #
      #   draw_text "PLAYER 3 PRESS START", 40, 80, :white if players_connected >= 3
      #
      # A console that reads one controller answers 1.
      def players_connected
        DSL::Value.new(self, Build.players_connected)
      end

      # THE MOST PLAYERS THIS BUILD SEATS, a Ruby number while the game is built, as `screen_width`
      # is: the top of what `players:` sets for this build. A game names its players once, and lays
      # out its seats from this, so the two cannot drift apart.
      #
      #   VBlank.game "PARTY", consoles: %i[gba], players: { computer: 1..4, else: 1 } do
      #     walkers = (1..most_players).map { |player| sprite :walker, at: [20 * player, 80] }
      #
      # A game that sets no `players:` has no number to give, so this is a friendly error: a build
      # seats what the console reads, and a computer build up to sixteen, which a game never means.
      def most_players
        @program.most_players or raise ArgumentError,
                                       "`most_players` needs `players:` on `VBlank.game`, and this game does not say it. " \
                                       "To fix this, say how many players the game takes, for example `players: 4`."
      end

      # SHAKE THE PLAYER'S HANDS for +frames+ frames, as a ball hitting a bumper does. +pattern+
      # sets on which frames the motor runs, eight of them at a time and round again: a String of
      # eight, "#" for on and "." for off, read from the left. Steady by default; "#.#.#.#." is a
      # light buzz. A number is eight bits read as the Color's own games read theirs, so a pattern
      # taken from one of them plays the same (IR::Rumble).
      #
      #   rumble frames: 12
      #   rumble frames: 30, pattern: "##..##.."
      #
      # A rumble started while one runs takes its place, and `frames: 0` stops it. A rumble is
      # felt only on a console whose cartridge carries a motor (the Game Boy Color's); on any
      # other it does nothing, and the game plays the same.
      #
      # @param frames [Integer, DSL::Value] how many frames it lasts, 0 to 65535
      # @param pattern [String, Integer, DSL::Value] which of each eight frames the motor runs on
      def rumble(frames:, pattern: STEADY_RUMBLE)
        refuse_bad_rumble_frames!(frames)
        record(Build.rumble(frames: frames, pattern: rumble_bits!(pattern)))
      end

      # The motor on for every frame.
      STEADY_RUMBLE = 0xFF

      # MORE KEYS FOR A BUTTON ON A COMPUTER: the desktop window, `vblank run` and the web page
      # start with VBlank's keys (the arrows, X for A, Z for B, Return for Start) and these besides.
      # Nothing is taken away, and a console's cartridge is built as it would be without it.
      #
      #   computer_keys a: :d                  # D presses A, and X still does
      #   computer_keys a: :d, left: :space
      #
      # A key presses one button, so a key VBlank already gives a button, or keeps for the window
      # (P, N, M, F, Tab, Escape, the key above Tab), is a friendly error, and so is one of player 2's
      # keys (I J K L, O, U, 7 to 0) in a game for more than one player. A player can still change
      # every key in Controls, and Reset puts the game's layout back.
      def computer_keys(**keys)
        add_computer_controls!(:key, IR::ComputerControls.keys_entries!(keys, most_players: @program.most_players))
      end

      # MORE GAMEPAD BUTTONS FOR A BUTTON ON A COMPUTER, as `computer_keys` adds keys: the free ones
      # are :west, :north, :left_stick and :right_stick.
      #
      #   computer_gamepad a: :west
      def computer_gamepad(**buttons)
        add_computer_controls!(:pad, IR::ComputerControls.pads_entries!(buttons))
      end

      private

      # A game names its keys once, and its gamepad buttons once.
      def add_computer_controls!(kind, entries)
        given = @program.computer_controls || []
        if given.any? { |_, each, _| each == kind }
          verb = kind == :key ? "computer_keys" : "computer_gamepad"
          raise ArgumentError, "This game already names its `#{verb}`. To fix this, name them all in one line."
        end
        @program.computer_controls = given + entries
        nil
      end

      # +pattern+ as the eight bits IR::Rumble reads; a friendly error for one that is not eight
      # frames.
      def rumble_bits!(pattern)
        return pattern unless pattern.is_a?(String) || pattern.is_a?(Integer)

        bits = pattern.is_a?(String) ? rumble_string_bits(pattern) : pattern
        return bits if bits.is_a?(Integer) && bits.between?(0, 0xFF)

        raise ArgumentError, "`rumble pattern: #{pattern.inspect}` is not 8 frames of the motor. Give a number " \
                             "from 0 to 255, or a String of 8 characters, \"#\" for on and \".\" for off."
      end

      def rumble_string_bits(pattern)
        return nil unless pattern.length == 8 && pattern.delete("#.").empty?

        IR::Rumble.bits_of(pattern.chars.map { |char| char == "#" })
      end

      def refuse_bad_rumble_frames!(frames)
        return unless frames.is_a?(Integer) && !frames.between?(0, IR::Rumble::MOST_FRAMES)

        raise ArgumentError, "`rumble frames: #{frames}` is not from 0 to #{IR::Rumble::MOST_FRAMES}. Give the " \
                             "number of frames the motor runs for, or 0 to stop it."
      end

      # Accept a known button name (from the shared IR vocabulary); raise a plain
      # error for anything else.
      def check_button!(button)
        return if IR::Buttons.readable?(button)

        raise ArgumentError, "#{button} is not a known button. Use one of these: :a :b :select :start :right :left :up :down :r :l."
      end

      def check_player!(player)
        unless IR::Buttons.player?(player)
          raise ArgumentError, "`player: #{player.inspect}` is not a player. Use a number from 1 to " \
                               "#{IR::Buttons::MOST_PLAYERS}, or :any for every player."
        end
        most = @program.most_players
        return if most.nil? || player == IR::Buttons::ANY || player <= most

        raise ArgumentError, "This line reads player #{player}, and the game takes at most #{most} " \
                             "#{most == 1 ? 'player' : 'players'} on this build (`players:`). To fix this, read a " \
                             "player from 1 to #{most}, or set the most players in `players:` to #{player} or more."
      end

      # The refusal for `if_held :a` (+test+ is :held or :pressed), naming `if held(:a)`.
      def button_test_message(test, button, player)
        on = player == 1 ? "" : ", player: #{player.inspect}"
        DSL::ChangingWord.low_level_test_refusal(:"if_#{test}", "if #{test}(#{button.inspect}#{on})",
                                                 at: Messages::AuthorSource.at_author_line)
      end

      # held/pressed hand back a Condition and take no block. A block here means a
      # game test written with a block — the block would attach to held/pressed and be silently
      # ignored — so name the fix instead of losing the code.
      def reject_block!(verb, button)
        raise ArgumentError,
              "#{verb}(:#{button}) takes no block. To run code, write `if #{verb}(:#{button})`."
      end
    end
  end
end
