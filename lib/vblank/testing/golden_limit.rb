# frozen_string_literal: true

module VBlank
  module Testing
    # HOW LONG THE GOLDEN PATH MAY TAKE, every lowering together. It is the run somebody plays every
    # day, and a run past this fails, though every test in it passed, so it does not grow into the
    # run nobody does.
    #
    # RakeTasks holds `rake test:golden` to it. A game that keeps a rake of its own calls it alone,
    # around however it plays its golden list, with nothing else of the library's loaded:
    #
    #   require "vblank/testing/golden_limit"
    #   VBlank::Testing::GoldenLimit.hold(list: "test/golden.txt") { play_the_golden_files }
    module GoldenLimit
      MOST_SECONDS = 480

      module_function

      # Plays the block, and stops the rake with what happened if it took more than +most_seconds+.
      # +list+ is the file that names the golden tests, for the words that say what to do about it.
      def hold(list:, most_seconds: MOST_SECONDS)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).ceil
        abort too_long_message(seconds, most_seconds, list) if seconds > most_seconds
      end

      def too_long_message(seconds, most_seconds, list)
        "The golden path took #{seconds} seconds, and its limit is #{most_seconds} seconds. " \
          "To fix this, remove a file from #{list}, or make its tests shorter."
      end
    end
  end
end
