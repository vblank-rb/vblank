# frozen_string_literal: true

module VBlank
  module Bots
    # A BOT THAT PLAYS ONE PLAYER'S PRESSES FROM A TAPE of passes (Playthroughs::Tape), such as the tape a
    # match kept (Network::Lockstep#tape). Played by one bot for each player, in one match, it gives the match
    # the tape was made of: the same buttons on the same passes, and so the same game.
    #
    # The tape's pass k is the pass the game reads its buttons for k + 1 (pass 1 sets the game up and reads
    # none). A press is used by the match the input delay after it is sent, so the bot asks for the tape's
    # pass k at the end of pass k - delay, and the first +delay+ passes of a tape are nothing in any
    # match: a tape a match kept starts with that many passes of nothing for that reason.
    class TapeBot
      attr_reader :name

      # +player+ is the player whose buttons on the tape this bot presses.
      def initialize(tape, player:, name: "tape of player #{player}")
        @name = name
        @player = player
        @passes = passes_of(tape)
      end

      def plays = nil

      # The tape's buttons for this bot's player, for the pass that will use what is asked now.
      def buttons_for(view)
        index = view.pass + view.input_delay # the tape's pass, counted from 1
        names = @passes.fetch(index - 1, [])
        Array(names).select { |button| IR::Buttons.player_of(button) == @player }.map { |button| IR::Buttons.button_of(button) }
      end

      private

      # The tape as a list with one entry for each pass: the buttons down on it.
      def passes_of(tape)
        raise ArgumentError, "A bot plays a tape of passes, and this tape counts frames. To fix this, record it in passes." unless tape.in_passes

        tape.steps.flat_map { |step| step.respond_to?(:buttons) ? [step.buttons] * step.frames : [] }
      end
    end
  end
end
