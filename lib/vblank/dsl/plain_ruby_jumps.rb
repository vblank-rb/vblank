# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # `break` and `next` in a loop the game runs: a `while` or `until` on a test the game makes,
      # a counting loop over a game number (Counts), or a `loop do` in game code.
      #
      # A game block runs once, to record the loop's body, so Ruby's own jump cannot happen while
      # the game plays: it would stop the recording part way. Instead the loop keeps a hidden
      # number, 0 while a round goes on, NEXT_ROUND once `next` ran and LEAVE once `break` ran. A
      # jump sets it, and everything recorded after the jump, up to the end of the round, goes in
      # a test that it is still 0 (Builder#open_jump_guard): the statements after the jump on its
      # own side, and those after each side and loop around it. The loop's test stops it once
      # `break` ran, and a loop with a `next` sets the number back to 0 as each round starts.
      #
      # In a loop Ruby runs while building, a jump is Ruby's own, as long as no test the game
      # makes stands between it and its loop: that test has no answer yet.
      class Jumps
        NEXT_ROUND = 1
        LEAVE = 2

        # +words+ are the jumps written in the loop's own body, `:break` and `:next`.
        def initialize(words)
          @words = words
          @flag = nil
        end

        def game? = !@flag.nil?

        # The loop is one the game runs: its hidden number starts at 0, recorded before the loop.
        def open_game!(builder)
          @builder = builder
          @flag = builder.hidden_variable(:jump)
          @flag.store!(0)
        end

        # Holds once `break` ran, for the loop's own test to stop on; nil with no `break`.
        def leave_test = (@flag == LEAVE if @words.include?(:break))

        # +statements+ in a test that holds until `break` ran, not yet recorded anywhere.
        def unless_left(statements)
          IR::Build.if_(IR::Build.binop(:!=, Value.node_for(@flag), IR::Build.int(LEAVE)), *statements)
        end

        # Recorded first in each round of a loop with a `next`.
        def start_round! = (@flag.store!(0) if @words.include?(:next))

        # The end of a round recorded by a block (Counts): the tests a jump opened are closed.
        def end_round! = @builder.close_jump_guards

        # A round of `loop do` (Counts.endless) starts here. The loop is Ruby's, run while
        # building, until a jump in it sits under a test the game makes: from that jump on it is
        # the game's (#open_game_at_round_start!).
        def note_round_start!(builder)
          @builder = builder
          @round_mark = builder.statement_mark
        end

        # `break` or `next`, under +tests+, the tests the game or Ruby asks between the jump and
        # this loop. True when Ruby makes the jump itself.
        def jump!(word, tests, with_value: false)
          open_game_at_round_start! if !game? && @round_mark && tests.any?(&:game?)
          return plain_jump!(word, tests) unless game?

          refuse_jump_with_value!(word) if with_value
          @flag.store!(word == :break ? LEAVE : NEXT_ROUND)
          @builder.open_jump_guard(@flag)
          false
        end

        # What the round that made the loop the game's recorded, after its hidden number's start.
        def round_statements
          children = @round_mark.container.children
          start = @round_mark.last ? children.index { |statement| statement.equal?(@round_mark.last) } + 1 : 0
          children[(start + 1)..]
        end

        # What one round of +repeat+, the game's loop, recorded, after setting the hidden number back.
        def round_body(repeat) = @words.include?(:next) ? repeat.children.drop(1) : repeat.children

        private

        # The rounds before this one were Ruby's, written out, and right as they are. This one
        # becomes the game's at the jump: its hidden number is set to 0 where the round started,
        # so the lines before the jump run as written and those after it wait on the test.
        def open_game_at_round_start!
          @flag = @builder.hidden_variable(:jump)
          @flag.store!(0)
          @builder.move_last_statement_to(@round_mark)
        end

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
