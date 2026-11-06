# frozen_string_literal: true

module VBlank
  module Playthroughs
    # A PLAYING COUNTED IN PASSES AND NOT FRAMES: a running game whose `step` plays passes of the game
    # loop, keeping the buttons down for however many frames each one takes. A game too heavy for a
    # frame takes two or three over a pass, so a frame is a different moment of the game on each way
    # of running it, and one setting that changes the speed moves every press. The game reads its
    # buttons once a pass, so the buttons of a pass mean the same thing everywhere.
    #
    # The buttons change once the count has moved, which is after a pass has ended and before the
    # next has read them.
    #
    # +counted+ chooses what counts: true for the passes of the game loop, or the name of a variable the
    # game adds to itself, for a game with stretches that keep to the frame (a fade, a tally) around
    # the part that counts.
    class PassSteppedGame
      # How many frames can go by with the count standing still before the playing stops: a minute.
      MOST_FRAMES_STILL = 3600

      # How many frames have been played so far.
      attr_reader :frames_played

      def initialize(game, counted)
        @game = game
        @counted = counted
        @frames_played = 0
        count_now
      end

      def step(count = 1, keys: nil)
        count.times { play_one_pass(keys) }
        self
      end

      def respond_to_missing?(question, include_private = false) = @game.respond_to?(question, include_private) || super

      # Everything else is the game's to answer: this only changes what a step is.
      def method_missing(question, ...)
        return super unless @game.respond_to?(question)

        @game.public_send(question, ...)
      end

      private

      def play_one_pass(keys)
        from = count_now
        MOST_FRAMES_STILL.times do
          @game.step(1, keys: keys)
          @frames_played += 1
          return if count_now > from
        end
        raise PassesStopped.new(@counted, from)
      end

      def count_now = @counted == true ? @game.passes : @game.var(@counted)
    end

    # A COUNT THAT STOPPED MOVING. The playing wanted one more pass, and a minute of frames went by
    # with none. A game that has ended does this, and so does a variable that only counts on some
    # stretches of the game.
    class PassesStopped < StandardError
      def initialize(counted, count)
        what = counted == true ? "the game loop's passes" : "the variable #{counted}"
        super("A playing counted #{what}, and the count stopped at #{count}. It did not move in " \
              "#{PassSteppedGame::MOST_FRAMES_STILL} frames, so the playing stopped. The game ended there, or it is on " \
              "a stretch that does not add to the count. To fix this, count something that goes on moving on that stretch.")
      end
    end
  end
end
