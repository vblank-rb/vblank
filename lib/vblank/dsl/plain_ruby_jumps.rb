# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # `break` and `next` in a loop the game runs: a `while` or `until` on a test the game makes,
      # a counting loop over a game number (Counts), or a `loop do` in game code.
      #
      # A game block runs once, to record the loop's body, so Ruby's own jump cannot happen while
      # the game plays: it would stop the recording part way. Instead the jump is recorded where it
      # was written, as a jump out of the loop or to its next round (IR::LoopJumps), and Ruby goes
      # on recording the rest of the round, which the game then skips as Ruby would.
      #
      # In a loop Ruby runs while building, a jump is Ruby's own, as long as no test the game
      # makes stands between it and its loop: that test has no answer yet.
      class Jumps
        # +words+ are the jumps written in the loop's own body, `:break` and `:next`.
        def initialize(words)
          @words = words
          @game = false
        end

        def game? = @game

        # The loop is one the game runs.
        def open_game!(builder)
          @builder = builder
          @game = true
        end

        # A round of `loop do` (Counts.endless) starts here. The loop is Ruby's, run while
        # building, until a jump in it sits under a test the game makes: from that round on it is
        # the game's (#game_round_statements).
        def note_round_start!(builder)
          @builder = builder
          @round_mark = builder.statement_mark
        end

        # `break` or `next`, under +tests+, the tests the game or Ruby asks between the jump and
        # this loop. True when Ruby makes the jump itself.
        def jump!(word, tests, with_value: false)
          @game = true if !game? && @round_mark && tests.any?(&:game?)
          return plain_jump!(word, tests) unless game?

          refuse_jump_with_value!(word) if with_value
          @builder.record_loop_jump(word)
          false
        end

        # What the round that made the loop the game's recorded, taken back out: the rounds before
        # it were Ruby's, written out and right as they are, and this one is the first round of
        # the game's loop, recorded again inside it.
        def game_round_statements = @builder.take_statements_since(@round_mark)

        private

        def plain_jump!(word, tests)
          tests.each { |test| test.refuse_jump!(word) }
          true
        end

        def refuse_jump_with_value!(word)
          Steps.refuse_game_code!("`#{word}` gives a value here, in a loop the game runs. The game cannot give a " \
                                  "value from a loop. To fix this, set a variable before the `#{word}`, and " \
                                  "write `#{word}` alone.")
        end
      end
    end
  end
end
