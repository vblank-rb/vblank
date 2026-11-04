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

      # The number a game variable holds, by the name the game gave it (a Symbol). The names a game has are
      # in #variable_names; a name the game does not have is a friendly error that lists them.
      def var(name)
        vars = state.vars
        vars.fetch(name.to_s) do
          raise ArgumentError, "The game has no variable named #{name.inspect}. It has: #{vars.keys.first(30).join(', ')}" \
                               "#{' and more' if vars.size > 30}."
        end
      end

      # A list the game keeps, oldest first, by its name.
      def list(name)
        lists = state.lists
        lists.fetch(name.to_s) do
          raise ArgumentError, "The game has no list named #{name.inspect}. It has: #{lists.keys.join(', ')}."
        end
      end

      def variable_names = state.vars.keys.map(&:to_sym)

      private

      def state = @state ||= @game.state
    end
  end
end
