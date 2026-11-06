# frozen_string_literal: true

module VBlank
  module Live
    # HOW MANY OF A PLAY'S PASSES RAN LATE, AND HOW MUCH OF THAT WAS RUBY COLLECTING GARBAGE, as the
    # play ends (LatenessTally counts it as the play goes).
    #
    # A pass is late when the game's own work over it — from the buttons handed to it to the picture
    # it hands back, so not the window drawing the picture or the wait for the frame to end — took
    # longer than one of the console's frames. On the console that pass would have missed the end of
    # its frame.
    #
    # Ruby collects garbage whenever making an object finds no room for it, and that can be in the
    # middle of a pass: the game stops while Ruby finds which objects nothing uses any more. So each
    # late pass also counts how long Ruby spent collecting inside it, and +late_because_of_collection+
    # the late passes that would have been on time without that. Those are the ones collecting at
    # another moment could have saved; the rest were late from the game's own work.
    #
    # +passes+ leaves out the pass the game set itself up in and the passes played in fast forward
    # (+fast_forward_passes+), which are meant to run long. +collection_timed+ is false on a Ruby that
    # cannot report how long it spends collecting (no GC.total_time), and the collection numbers are then
    # nought. +setup_collection_seconds+ is the full collection run after setup, or nil if none was.
    Lateness = Data.define(:passes, :late_passes, :late_because_of_collection, :most_late_seconds,
                           :collection_seconds_in_late, :fast_forward_passes, :collection_timed,
                           :setup_collection_seconds) do
      # What a person reads when the play ends.
      def words = [late_words, setup_words].compact.join(" ")

      private

      def late_words
        counted = "Of the #{passes} passes after the one the game set itself up in" \
                  "#{", leaving out #{fast_forward_passes} played in fast forward" if fast_forward_passes.positive?}"
        return "#{counted}, none ran longer than a frame." if late_passes.zero?

        late = format("%<counted>s, %<late>d ran longer than a frame, by %<most>.1f ms at most.",
                      counted: counted, late: late_passes, most: most_late_seconds * 1000)
        return "#{late} This Ruby does not say how long it spends collecting garbage." unless collection_timed
        return "#{late} Ruby collected no garbage in them." unless collection_seconds_in_late.positive?

        format("%<late>s Collecting garbage took %<collection>.1f ms of their time. Without it, %<only>d of them would " \
               "have been on time.", late: late, collection: collection_seconds_in_late * 1000, only: late_because_of_collection)
      end

      def setup_words
        return nil unless setup_collection_seconds
        return "Garbage was collected once after the game set itself up." unless collection_timed

        format("Garbage was collected once after the game set itself up, in %<ms>d ms.", ms: (setup_collection_seconds * 1000).round)
      end
    end

    # The count behind a Lateness, kept by Session a pass at a time.
    class LatenessTally
      # GC.total_time is CRuby's; a Ruby without it plays on with the collection left uncounted.
      COLLECTION_TIMED = GC.respond_to?(:total_time)
      NANOSECONDS_A_SECOND = 1_000_000_000 # GC.total_time counts in these

      # The nanoseconds Ruby has spent collecting since it started, or nought where it cannot report it.
      def self.collection_clock = COLLECTION_TIMED ? GC.total_time : 0

      # The seconds Ruby spent collecting since #collection_clock read +began+.
      def self.seconds_collecting_since(began) = Rational(collection_clock - began, NANOSECONDS_A_SECOND)

      def initialize(frame_seconds:)
        @frame_seconds = frame_seconds
        @passes = @late_passes = @late_because_of_collection = @fast_forward_passes = 0
        @most_late_seconds = @collection_seconds_in_late = 0
        @setup_collection_seconds = nil
      end

      # One pass: the seconds the game worked over it, and the seconds of those Ruby spent collecting.
      def record(work_seconds:, collection_seconds:)
        @passes += 1
        late_by = work_seconds - @frame_seconds
        return unless late_by.positive?

        @late_passes += 1
        @most_late_seconds = [@most_late_seconds, late_by].max
        @collection_seconds_in_late += collection_seconds
        @late_because_of_collection += 1 if work_seconds - collection_seconds <= @frame_seconds
      end

      # A pass played in fast forward, which is not timed.
      def record_fast_forward = @fast_forward_passes += 1

      # The full collection run once the game had set itself up took +seconds+ (Session).
      def record_setup_collection(seconds)
        @setup_collection_seconds = seconds
      end

      def lateness
        Lateness.new(passes: @passes, late_passes: @late_passes, late_because_of_collection: @late_because_of_collection,
                     most_late_seconds: @most_late_seconds, collection_seconds_in_late: @collection_seconds_in_late,
                     fast_forward_passes: @fast_forward_passes, collection_timed: COLLECTION_TIMED,
                     setup_collection_seconds: @setup_collection_seconds)
      end
    end
  end
end
