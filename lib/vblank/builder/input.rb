# frozen_string_literal: true

module VBlank
  class Builder
    # The input verbs: gate a block on a button — if_held / if_pressed — or turn a
    # button into a {Condition} — held / pressed — to branch with `if` and
    # join with `&&` / `||`. Button names are validated against the shared IR
    # vocabulary. A concern of {Builder}, mixed in so these stay flat DSL verbs.
    module Input
      # Run the block only while a button is held down.
      #
      # @param button [Symbol] :up, :down, :left, :right, :a, :b, :start, :select, :l, :r
      # @param player [Integer, Symbol] whose controller: 1 to IR::Buttons::MOST_PLAYERS, or :any for
      #   every connected player
      def if_held(button, player: 1, &block)
        check_button!(button)
        check_player!(player)
        push_container(Build.if_(Build.held(button, player: player))) do
          run_block(&block)
        end
      end

      # Run the block when a button is first pressed (edge-detected): down this
      # frame, up the previous one.
      #
      # @param button [Symbol] button name
      # @param player [Integer, Symbol] whose controller: 1, 2, or :any for either
      def if_pressed(button, player: 1, &block)
        check_button!(button)
        check_player!(player)
        push_container(Build.if_(Build.pressed(button, player: player))) do
          run_block(&block)
        end
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

      private

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

      # held/pressed hand back a Condition and take no block. A block here means a
      # game test written with a block — the block would attach to held/pressed and be silently
      # ignored — so name the fix instead of losing the code.
      def reject_block!(verb, button)
        raise ArgumentError,
              "#{verb}(:#{button}) takes no block. To run code, write `if #{verb}(:#{button})`. " \
              "Or use the block form: if_#{verb} :#{button} do ... end."
      end
    end
  end
end
