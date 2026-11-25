# frozen_string_literal: true

module VBlank
  class Builder
    # Buttons and players
    #
    # `held(:left)` and `pressed(:start)` ask about a button. Each answers a yes or no that you
    # use with `if`, and join with `&&` and `||`. The buttons are `a`, `b`, `select`, `start`,
    # `right`, `left`, `up`, `down`, `r` and `l`, with `x` and `y` on the Super Nintendo and the
    # PlayStation, `c` on the Genesis, and `l2` and `r2` on the PlayStation. A button the console does
    # not have is an error when the game is built. A PlayStation's buttons can also be named as its pad
    # names them: `:cross` is `:a`, `:circle` `:b`, `:triangle` `:x`, `:square` `:y`, `:l1` `:l` and
    # `:r1` `:r`.
    #
    # ```ruby
    # game_loop do
    #   x -= 2 if held(:left)
    #   x += 2 if held(:right)
    #   score += 1 if pressed(:a)
    # end
    # ```
    #
    # A game for more than one player asks about another controller with `player:`, and
    # `players_connected` says how many people are playing. On a computer, `computer_keys` and
    # `computer_gamepad` add keys and gamepad buttons to the ones VBlank gives.
    #--
    # Button names are validated against the shared IR vocabulary. A concern of Builder, mixed in
    # so these stay flat DSL verbs.
    #++
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

      # Asks whether a button is down right now. It holds for as long as the button is held.
      #
      # ```ruby
      # y -= 1 if held(:up)
      # y += 1 if held(:down, player: 2)   # the second controller
      # leave_title if held(:any)          # any button at all
      # ```
      #
      # * `button` - the button's name, as a symbol, or `:any` for any button.
      # * `player:` - whose controller: a number from 1, or `:any` for every connected player.
      def held(button, player: 1, &)
        reject_block!(:held, button) if block_given?
        check_button!(button)
        check_player!(player)
        DSL::Condition.new(self, Build.held(IR::Buttons.named(button), player: player))
      end

      # Asks whether a button went down on this frame.
      #
      # It holds once for each press, on the frame the button goes down, and not again until the
      # button is let go and pressed again. Use it for a jump or a menu choice, where holding the
      # button must not count twice. Use `held` for movement.
      #
      # ```ruby
      # fire if pressed(:a)
      # mode = :playing if pressed(:start, player: :any)
      # ```
      #
      # * `button` - the button's name, as a symbol, or `:any` for any button.
      # * `player:` - whose controller: a number from 1, or `:any` for every connected player.
      def pressed(button, player: 1, &)
        reject_block!(:pressed, button) if block_given?
        check_button!(button)
        check_player!(player)
        DSL::Condition.new(self, Build.pressed(IR::Buttons.named(button), player: player))
      end

      # Reads how far a button is pulled, as a number from 0 (let go) to 100 (all the way).
      #
      # It is for a trigger that can be pulled part of the way, as a gamepad's L2 and R2 can be on a
      # computer: a pedal, a throttle, a bow drawn back. Every other button is all or nothing, so it
      # reads 100 while the button is held and 0 when it is not. A PlayStation's own pad has L2 and
      # R2 that are all or nothing too.
      #
      # ```ruby
      # speed = pulled(:r2) / 25         # 0 to 4
      # brake = pulled(:l2, player: 2)
      # ```
      #
      # `held(:l2)` stays a plain yes or no: a trigger counts as held from a small pull.
      #
      # * `button` - the button's name, as a symbol.
      # * `player:` - whose controller: a number from 1.
      #--
      # A cartridge answers it as `held` times 100 (IR::Build.pulled_as_held); only a build for a
      # computer reads a trigger part pulled (IR::Buttons::PULLED_BUTTONS).
      #++
      def pulled(button, player: 1, &)
        reject_block!(:pulled, button) if block_given?
        refuse_pull_of_any!(button, player)
        check_button!(button)
        check_player!(player)
        DSL::Value.new(self, Build.pulled(IR::Buttons.named(button), player: player))
      end

      # Reads how many players are connected now, as a number that is at least 1.
      #
      # A player counts from the first time one of their buttons is down, and stays counted.
      # Letting go of every button is not unplugging. Ask before reading a player's buttons, so
      # that the game never waits on a player who is not there.
      #
      # ```ruby
      # draw_text "PLAYER 3 PRESS START", 40, 80, :white if players_connected >= 3
      # ```
      #
      # A console that reads one controller answers 1.
      def players_connected
        DSL::Value.new(self, Build.players_connected)
      end

      # Gives the most players this build seats, as a plain Ruby number while the game is built.
      #
      # It is the top of what `players:` sets for this build. A game names its players once and
      # lays out its seats from this number, so that the two cannot drift apart.
      #
      # ```ruby
      # VBlank.game "PARTY", consoles: %i[gba],
      #             players: { computer: 1..4,
      #                        else: 1 } do
      #   screen :tiled, backdrop: rgb(3, 4, 7)
      #   image(:walker, "#" => :yellow) do
      #     "################\n" * 16
      #   end
      #   (1..max_players).each do |player|
      #     x = 84 + 28 * player
      #     sprite :walker, at: [x, 72]
      #   end
      #   game_loop {}
      # end
      # ```
      #
      # A game that sets no `players:` has no number to give, and `max_players` raises an error
      # that says so.
      #--
      # A build seats what the console reads, and a computer build up to sixteen, which a game
      # never means.
      #++
      def max_players
        @program.max_players or raise ArgumentError,
                                      "`max_players` needs `players:` on `VBlank.game`, and this game does not say it. " \
                                      "To fix this, say how many players the game takes, for example `players: 4`."
      end

      #--
      # The verb's old name, kept only to say the new one. Private, so it is no verb of the DSL's:
      # a game's block still reaches it, since it runs as the builder.
      #++
      private def most_players
        raise ArgumentError, "`most_players` is now `max_players`. To fix this, write `max_players`."
      end

      # Shakes the player's hands for a number of frames, as a ball hitting a bumper does.
      #
      # A rumble started while one runs takes its place, and `frames: 0` stops it. It is felt only
      # on a console whose cartridge carries a motor, which is the Game Boy Color. On any other
      # console it does nothing, and the game plays the same.
      #
      # ```ruby
      # rumble frames: 12
      # rumble frames: 30, pattern: "##..##.."
      # ```
      #
      # * `frames:` - how many frames it lasts, from 0 to 65535.
      # * `pattern:` - on which frames the motor runs, eight at a time and round again. Write a
      #   string of eight, `"#"` for on and `"."` for off, read from the left. It is steady by
      #   default, and `"#.#.#.#."` is a light buzz.
      #--
      # A number pattern is eight bits read as the Color's own games read theirs, so a pattern
      # taken from one of them plays the same (IR::Rumble).
      #++
      def rumble(frames:, pattern: STEADY_RUMBLE)
        refuse_bad_rumble_frames!(frames)
        record(Build.rumble(frames: frames, pattern: rumble_bits!(pattern)))
      end

      # The motor on for every frame.
      STEADY_RUMBLE = 0xFF  # :nodoc:

      # Adds keys for a button on a computer.
      #
      # The desktop window, `vblank run` and the web page start with VBlank's keys (the arrows,
      # X for A, Z for B, Return for Start) and use these besides. Nothing is taken away, and a
      # console's cartridge is built as it would be without them.
      #
      # ```ruby
      # computer_keys a: :d                  # D presses A, and X still does
      # computer_keys a: :d, left: :space
      # ```
      #
      # A key presses one button. A key that VBlank already gives a button, or keeps for the
      # window (P, N, M, F, Tab, Escape and the key above Tab), is an error, and so is one of
      # player 2's keys (I, J, K, L, O, U and 6 to 0) in a game for more than one player. A
      # player can still change every key in the Controls screen, and Reset puts the game's
      # layout back. A game names its keys once, in one line.
      #
      # * Each keyword is a button, and its value is the key that presses it.
      def computer_keys(**keys)
        add_computer_controls!(:key, IR::ComputerControls.keys_entries!(keys, console: console, max_players: @program.max_players))
      end

      # Adds gamepad buttons for a button on a computer, as `computer_keys` adds keys.
      #
      # The free ones are `:west`, `:north`, `:left_stick` and `:right_stick`. A console's X, Y or
      # C button starts on `:west`, `:north` and the sticks, so those are free only for the other
      # buttons.
      #
      # ```ruby
      # computer_gamepad a: :west
      # ```
      #
      # * Each keyword is a button, and its value is the gamepad button that presses it.
      def computer_gamepad(**buttons)
        add_computer_controls!(:pad, IR::ComputerControls.pads_entries!(buttons, console: console))
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

        raise ArgumentError, "#{button} is not a known button. Use one of these: :a :b :select :start :right :left :up :down :r :l, " \
                             "or :x :y :c :l2 :r2 on a console that has them."
      end

      # `pulled` reads one button of one player: how far "any" button is pulled has no answer.
      def refuse_pull_of_any!(button, player)
        if button == IR::Buttons::ANY
          raise ArgumentError, "`pulled(:any)` does not name a button. `pulled` reads how far one button is pulled. " \
                               "To fix this, name the button, for example `pulled(:r2)`."
        end
        return unless player == IR::Buttons::ANY

        raise ArgumentError, "`pulled(#{button.inspect}, player: :any)` does not name a player. `pulled` reads the " \
                             "controller of one player. To fix this, give a number, for example `player: 2`."
      end

      def check_player!(player)
        unless IR::Buttons.player?(player)
          raise ArgumentError, "`player: #{player.inspect}` is not a player. Use a number from 1 to " \
                               "#{IR::Buttons::MOST_PLAYERS}, or :any for every player."
        end
        most = @program.max_players
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
