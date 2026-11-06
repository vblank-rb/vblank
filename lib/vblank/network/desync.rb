# frozen_string_literal: true

module VBlank
  module Network
    # WHAT TWO MACHINES DISAGREED ABOUT. +pass+ is the first checkpoint at which their game states
    # differ, and +last_agreed_pass+ the checkpoint before it where every machine's state was the
    # same (0 when there was none), so the first pass that went wrong lies between the two. +crcs+
    # holds what each player's machine had at +pass+, by player number. +tape+ is the presses of the
    # match up to there, a Playthroughs::Tape of passes: played on the interpreter, it shows which
    # machine's state is the one the game really reaches.
    DesyncReport = Data.define(:pass, :last_agreed_pass, :crcs, :tape) do
      def to_s
        states = crcs.sort.map { |player, crc| "player #{player} has #{format('0x%08X', crc)}" }.join(", ")
        agreed = last_agreed_pass.zero? ? "At the start the states were the same." : "At pass #{last_agreed_pass} the states were the same."
        "The machines in this match disagree. At pass #{pass} the game states differ: #{states}. #{agreed} " \
          "So the first pass that differs is after that, and no later than pass #{pass}. " \
          "To find the cause, play the tape of the match on the interpreter."
      end
    end

    # RAISED ON A MACHINE THAT FOUND ITS GAME DIFFERS FROM ANOTHER'S. It stops the match there:
    # going on would only play two different games. A machine that agrees with the others
    # still stops, because every machine that compared the same two checkpoints finds the same.
    class Desync < StandardError
      attr_reader :report

      def initialize(report)
        @report = report
        super(report.to_s)
      end
    end
  end
end
