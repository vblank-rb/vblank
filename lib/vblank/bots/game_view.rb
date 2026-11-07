# frozen_string_literal: true

module VBlank
  module Bots
    # WHAT A BOT CAN SEE: its own copy of the game, read and never written. It is handed to the bot's block
    # once a pass, and answers the same questions the interpreter answers a test: a variable by its name, a
    # list by its name. The numbers are those of the pass just ended. There is nothing here that changes the
    # game; the bot's only effect is the buttons it answers.
    #
    # +player+ is which player the bot is, +players+ how many the match has, +pass+ the pass just ended (the
    # first is 1), and +input_delay+ how many passes the bot's buttons wait before the game uses them.
    class GameView
      attr_reader :player, :players, :pass, :input_delay

      def initialize(game, player:, players:, input_delay:)
        @game = game
        @player = player
        @players = players
        @input_delay = input_delay
        @pass = 0
      end

      # For the device: the pass that has just ended.
      def reached(pass)
        @pass = pass
        @state = nil
        self
      end

      # The number a game variable holds, by the name the game gave it (a Symbol), a fraction as the
      # fraction (Program#var_in_game_units). The names a game has are in #variable_names; a name the game
      # does not have is a friendly error that lists them.
      def var(name)
        vars = state.vars
        stored = vars.fetch(name.to_s) do
          raise ArgumentError, "The game has no variable named #{name.inspect}. It has: #{vars.keys.first(30).join(', ')}" \
                               "#{' and more' if vars.size > 30}."
        end
        program ? program.var_in_game_units(name.to_sym, stored) : stored
      end

      # A list the game keeps, oldest first, by its name.
      def list(name)
        lists = state.lists
        items = lists.fetch(name.to_s) do
          raise ArgumentError, "The game has no list named #{name.inspect}. It has: #{lists.keys.join(', ')}."
        end
        program ? program.list_in_game_units(name.to_sym, items) : items
      end

      # A sprite by the name the game gave it (`sprite :walker2, image: :walker`): its +x+, +y+,
      # whether it is #shown?, and the +pose+ it is showing (IR::SpriteState).
      def sprite(name)
        raise ArgumentError, "This game was made from its Ruby alone, so nothing names its sprites." unless program

        vars = state.vars
        program.sprite_state(name, ->(var) { vars.fetch(var.to_s, 0) })
      end

      # A background by the name the game declared it with: how far it is scrolled and the map it
      # has set showing (IR::BackgroundState).
      def background(name)
        raise ArgumentError, "This game was made from its Ruby alone, so nothing names its backgrounds." unless program

        vars = state.vars
        program.background_state(name, ->(var) { vars.fetch(var.to_s, 0) })
      end

      # The music's loudness, 0 to 100, as the game's own `music_volume` reads it.
      def music_volume
        raise ArgumentError, "This game was made from its Ruby alone, so nothing says how loud its music is." unless program

        vars = state.vars
        program.music_volume_from(->(var) { vars.fetch(var.to_s, 0) })
      end

      def variable_names = state.vars.keys.map(&:to_sym)

      private

      def state = @state ||= @game.state

      # The program the game was written from, or nil for a game made from its Ruby alone.
      def program = @game.program
    end
  end
end
