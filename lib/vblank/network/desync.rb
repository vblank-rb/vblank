# frozen_string_literal: true

module VBlank
  module Network
    # WHAT TWO MACHINES DISAGREED ABOUT. +pass+ is the first checkpoint at which their game states
    # differ, and +last_agreed_pass+ the checkpoint before it where every machine's state was the
    # same (0 when there was none), so the first pass that went wrong lies between the two. +crcs+
    # holds what each player's machine had at +pass+, by player number. +tape+ is the presses of the
    # match up to there as this machine played them, with the match's seed, a Playthroughs::Tape of
    # passes: played on the interpreter, it replays this machine's game pass for pass, so the picture
    # and the numbers of each pass show where this machine's game went.
    DesyncReport = Data.define(:pass, :last_agreed_pass, :crcs, :tape) do
      def to_s
        states = crcs.sort.map { |player, crc| "player #{player} has #{format('0x%08X', crc)}" }.join(", ")
        agreed = last_agreed_pass.zero? ? "At the start the states were the same." : "At pass #{last_agreed_pass} the states were the same."
        "The machines in this match disagree. At pass #{pass} the game states differ: #{states}. #{agreed} " \
          "So the first pass that differs is after that, and no later than pass #{pass}. " \
          "To find the cause, play the tape of the match on the interpreter."
      end

      # Where #write_in put the two files: the tape, and the report as words.
      Written = Data.define(:tape, :report)

      # THE TAPE AND THE REPORT WRITTEN INTO +folder+, for a person to keep after the match has
      # stopped: `match.tape`, which `vblank run GAME --tape match.tape --on interpreter` plays, and
      # `report.txt`, these words. Each machine writes its own, and the tapes of two machines that
      # went different ways hold different presses from the pass where they parted. Returns a Written.
      def write_in(folder)
        tape_path = tape.write(File.join(folder, "match.tape"))
        report_path = File.join(folder, "report.txt")
        File.write(report_path, "#{self}\n")
        Written.new(tape: tape_path, report: report_path)
      end

      # The report, then where #write_in put the files, and the command that replays the tape.
      def written_message(written)
        "#{self} The tape of the match is in #{written.tape}. This report is in #{written.report}. " \
          "To play the tape on the interpreter, run: vblank run GAME_FILE --tape #{written.tape} --on interpreter --no-window"
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
