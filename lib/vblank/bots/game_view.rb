# frozen_string_literal: true

module VBlank
  module Bots
    # WHAT A BOT CAN SEE: its own copy of the game, read and never written. It is handed to the bot's block
    # once a pass, and answers the same questions the interpreter answers a test (IR::ReadingByName): a
    # variable, a sprite, a background and the music's loudness by the names the game gave them, and a list
    # by its name. The numbers are those of the pass just ended. There is nothing here that changes the
    # game; the bot's only effect is the buttons it answers.
    #
    # +player+ is which player the bot is, +players+ how many the match has, +pass+ the pass just ended (the
    # first is 1), and +input_delay+ how many passes the bot's buttons wait before the game uses them.
    class GameView
      include IR::ReadingByName

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
        unless vars.key?(name.to_s)
          raise ArgumentError, "The game has no variable named #{name.inspect}. It has: #{vars.keys.first(30).join(', ')}" \
                               "#{' and more' if vars.size > 30}."
        end
        super
      end

      # Whether the game keeps a variable +name+, so #var can read it.
      def var?(name) = state.vars.key?(name.to_s)

      # How many passes of the game loop have finished, as a playthrough's script reads them: the pass
      # just ended.
      def passes = pass

      # A variable's stored number, as the game's runtime keeps it: 0 for one it has not written.
      def raw_var(name) = state.vars.fetch(name.to_s, 0)

      # A list the game keeps, oldest first, by its name.
      def list(name)
        lists = state.lists
        items = lists.fetch(name.to_s) do
          raise ArgumentError, "The game has no list named #{name.inspect}. It has: #{lists.keys.join(', ')}."
        end
        read_program ? read_program.list_in_game_units(name.to_sym, items) : items
      end

      def variable_names = state.vars.keys.map(&:to_sym)

      private

      def state = @state ||= @game.state

      # The program the game was written from, or nil for a game made from its Ruby alone.
      def read_program = @game.program

      def refuse_no_program!(what)
        raise ArgumentError, "This game was made from its Ruby alone, so nothing says #{what}."
      end
    end
  end
end
