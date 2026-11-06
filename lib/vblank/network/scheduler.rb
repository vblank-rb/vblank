# frozen_string_literal: true

module VBlank
  module Network
    # SEVERAL COPIES OF A GAME PLAYED IN ONE PROCESS, a round at a time. Each copy runs in a Fiber until it
    # must wait for a message (a transport's wait_for_message calls #wait), and the next copy then runs.
    # Nothing here keeps time: a round is one trip round every copy, so a test that delays a message by
    # three rounds delays it by three trips, and replays the same whatever machine runs it.
    #
    # +movement+ answers whether anything could happen in a round that did not happen in this one: a
    # message that is on its way, or something the test scheduled. When no copy finishes in a round and
    # +movement+ answers no, every copy waits for what will never come, and #play raises Stalled and names who
    # waits, so a test that would hang says why instead. +before_round+ is called with the round's
    # number as each round begins, which is where a test cuts or restores a link.
    class Scheduler
      # What a copy came to: the value it returned, or the error that stopped it.
      Outcome = Data.define(:value, :error)

      # Every copy waits and no message is on its way.
      class Stalled < StandardError; end

      attr_reader :round

      def initialize(movement:, before_round: nil, stalled_words: nil)
        @movement = movement
        @before_round = before_round
        @stalled_words = stalled_words
        @round = 0
        @fibers = {}
      end

      # Whether the caller is one of the copies being played, and so can wait for the others.
      def inside? = @fibers.key?(Fiber.current)

      # Gives the other copies their turn. Called by a copy that waits.
      def wait = Fiber.yield

      # Plays +copies+, each something callable, until every one has finished or failed. Gives back an
      # Outcome for each, in order. A copy's error ends only that copy.
      def play(copies)
        fibers = copies.map { |copy| Fiber.new { copy.call } }
        fibers.each_with_index { |fiber, index| @fibers[fiber] = index }
        outcomes = Array.new(copies.size)
        until outcomes.all?
          @round += 1
          @before_round&.call(@round)
          finished = run_round(fibers, outcomes)
          refuse_stall(outcomes) unless finished || outcomes.all? || @movement.call
        end
        outcomes
      ensure
        @fibers.clear
      end

      private

      # One trip round every copy still going. Returns whether any finished or failed in it.
      def run_round(fibers, outcomes)
        finished = false
        fibers.each_with_index do |fiber, index|
          next if outcomes[index]

          begin
            value = fiber.resume
            next if fiber.alive?

            outcomes[index] = Outcome.new(value: value, error: nil)
          rescue StandardError => error
            outcomes[index] = Outcome.new(value: nil, error: error)
          end
          finished = true
        end
        finished
      end

      def refuse_stall(outcomes)
        waiting = outcomes.each_index.select { |index| outcomes[index].nil? }.map { |index| index + 1 }
        extra = @stalled_words&.call
        raise Stalled, "Every copy is waiting and no message is on its way. Waiting: copies #{waiting.join(', ')}.#{" #{extra}" if extra} " \
                       "To fix this, let the message through, or make the copy that sends it play."
      end
    end
  end
end
