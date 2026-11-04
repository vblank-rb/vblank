# frozen_string_literal: true

module VBlank
  module Diagnostics
    # A FRAME'S TIME, BY ROUTINE, for a console whose emulator adds up the time each instruction took
    # by the address it started at (Core#take_processor_time on the Super Nintendo and the Genesis).
    # Every address is in a routine: one of the game's, which +routine_at+ names, or the runtime's,
    # found by the label before it. +waits+ matches the runtime's labels that are only waiting for
    # the screen: time there is time the game had to spare, and the fewest lines of it in any frame
    # is how near that frame came to running over.
    class TimeByRoutine
      # One routine and its share of all the time measured, from 0 to 1.
      Spent = Data.define(:routine, :share)

      # How much of the time went on waiting, the fewest lines any frame had to spare, and the
      # routines by share, the game's and the runtime's apart.
      Report = Data.define(:idle_share, :fewest_lines_spare, :game, :runtime)

      # Only the Advance's profile can put a button down as the measured frames begin.
      def self.refuse_press!(press, console)
        return if press.empty?

        raise ArgumentError, "A #{console} profile cannot press a button as the measuring starts yet. To fix this, leave " \
                             "out --press. To press a button on a given frame, give a tape of presses (--tape)."
      end

      # +code+ is a build's labels and their addresses, and +line+ how much of the emulator's count a
      # line of the picture takes. +game_labels+ matches the labels of the game's own code, for a
      # build that keeps no record of it to give +routine_at+.
      def initialize(code:, waits:, line:, routine_at: ->(_) {}, game_labels: nil)
        @labels = code.map { |label, address| [address, label] }.sort
        @starts = @labels.map(&:first)
        @waits = waits
        @line = line
        @routine_at = game_labels ? game_label_at(game_labels) : routine_at
      end

      # +by_frame+ is what the emulator counted in each frame.
      def report(by_frame)
        game = Hash.new(0)
        runtime = Hash.new(0)
        by_frame.each do |spent|
          spent.each do |address, time|
            routine = @routine_at.call(address)
            routine ? game[routine] += time : runtime[label_before(address)] += time
          end
        end
        total = (game.values.sum + runtime.values.sum).to_f
        waiting = runtime.select { |label, _| label.match?(@waits) }
        Report.new(idle_share: waiting.values.sum / total, fewest_lines_spare: by_frame.map { |spent| lines_spare(spent) }.min,
                   game: by_share(game, total), runtime: by_share(runtime.except(*waiting.keys), total))
      end

      # The report's routines, for a person.
      def self.render(report, out:)
        { "Your routines" => report.game, "The runtime" => report.runtime }.each do |heading, spent|
          next if spent.empty?

          out.puts "", "#{heading}:"
          spent.first(12).each { |row| out.puts format("  %5.1f%%  %s", row.share * 100, row.routine) }
        end
      end

      private

      def game_label_at(game_labels)
        lambda do |address|
          label = label_before(address)
          label if label.match?(game_labels)
        end
      end

      def lines_spare(spent)
        spent.sum { |address, time| !@routine_at.call(address) && label_before(address).match?(@waits) ? time : 0 } / @line
      end

      def by_share(time_by_routine, total)
        time_by_routine.sort_by { |_, time| -time }.map { |routine, time| Spent.new(routine: routine, share: time / total) }
      end

      def label_before(address)
        at = (@starts.bsearch_index { |start| start > address } || @starts.length) - 1
        at.negative? ? "somewhere with no label" : @labels[at][1]
      end
    end
  end
end
