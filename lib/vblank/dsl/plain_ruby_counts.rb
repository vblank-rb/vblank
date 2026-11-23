# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # Ruby's counting loops, `n.times`, `a.upto(b)`, `a.downto(b)`, `a.step(b, by)`, a range's
      # `each` and `step`, and `for x in a...b`, as a rewritten game block calls them.
      #
      # On plain numbers each is Ruby's own and runs while building, written out once a round.
      # Where a number at either end is one the game keeps, nobody knows while building how many
      # rounds there are, so the loop is one the game runs as it plays (Builder#repeat): it goes
      # round as many times as Ruby's would, handing the block each number Ruby would hand it.
      # Ruby reads the start and the count once, as the loop begins, and so does the game's loop.
      module Counts
        module_function

        # What `n.times { }` and its kin are asked of. A number, plain or the game's, answers
        # through a Start; anything else is left to answer for itself.
        def start(value) = value.is_a?(Integer) || value.is_a?(Value) ? Start.new(value) : value

        # The range of `(a...b).each { }` or `for x in a...b`: Ruby's own on plain numbers.
        def range(from, upto, exclusive)
          return Range.new(from, upto, exclusive) unless [from, upto].any?(Value)

          GameRange.new(from, upto, exclusive)
        end

        def game?(*values) = values.any?(Value)

        # Goes round +rounds+ times as a loop the game runs, handing the block +first+, then
        # +first+ plus +by+, and so on. +first+ must not change while the loop runs (#held).
        def game_loop(first, rounds, by)
          VBlank::Builder.in_use.repeat(rounds) do |index|
            number = by == 1 ? index : index * by
            number += first unless first.is_a?(Integer) && first.zero?
            yield number
          end
        end

        # A game number the loop starts from, kept as it is when the loop begins: the body may
        # change the variable, and Ruby's loop goes on from the number it started with.
        def held(value) = value.is_a?(Value) && value.changes_as_game_plays? ? value.hidden_copy(:count_start) : value

        def refuse_unknown_step!(by)
          return if by.is_a?(Integer) && !by.zero?

          Steps.refuse_game_code!("This `step` uses a number that the game keeps, so the game counts as it plays. " \
                                  "Then the step must be a whole number in the code, and not 0, as in " \
                                  "`0.step(n, 2)`. To fix this, write the step as a number.")
        end

        # A number that `times`, `upto`, `downto` or `step` is asked of, with a block.
        class Start
          def initialize(start) = @start = start

          def times(&)
            return @start.times(&) unless Counts.game?(@start)

            Counts.game_loop(0, @start, 1, &)
            @start
          end

          def upto(last, &)
            return @start.upto(last, &) unless Counts.game?(@start, last)

            first = Counts.held(@start)
            Counts.game_loop(first, last - first + 1, 1, &)
            @start
          end

          def downto(last, &)
            return @start.downto(last, &) unless Counts.game?(@start, last)

            first = Counts.held(@start)
            Counts.game_loop(first, first - last + 1, -1, &)
            @start
          end

          # `a.step(limit, by)` or `a.step(by:, to:)`. Ruby's rounds are every number from the
          # start to the limit, +by+ apart. Adding +by+ before dividing counts the start itself,
          # and gives no rounds for a limit behind the start, whichever way the divide rounds.
          def step(*given, **options, &)
            return @start.step(*given, **options, &) unless Counts.game?(@start, *given, *options.values)

            limit = options.fetch(:to, given[0])
            by = options.fetch(:by, given[1] || 1)
            Counts.refuse_unknown_step!(by)
            Counts.refuse_endless!("step") if limit.nil?
            first = Counts.held(@start)
            rounds = by.positive? ? (limit - first + by) / by : (first - limit - by) / -by
            Counts.game_loop(first, rounds, by, &)
            @start
          end
        end

        def refuse_endless!(verb)
          Steps.refuse_game_code!("This `#{verb}` starts at a number that the game keeps and has no end. The game " \
                                  "can count only to an end that is given. To fix this, give the end, as in " \
                                  "`(n..9).each`.")
        end

        # A range with a number the game keeps at one end. The game counts through it as it plays,
        # so it goes round with `each` or `step`, and `for` asks it for `each`.
        class GameRange
          def initialize(from, upto, exclusive)
            @from = from
            @upto = upto
            @exclusive = exclusive
          end

          def each(&)
            Start.new(@from).upto(last, &)
            self
          end

          def step(by, &)
            Start.new(@from).step(last, by, &)
            self
          end

          def method_missing(name, *, &)
            Steps.refuse_game_code!("This range goes to a number that the game keeps, and it is asked for " \
                                    "`#{name}`. The game counts through such a range as it plays, so the range can " \
                                    "only go round with `each` or `step`, or in a `for` loop. To fix this, write " \
                                    "`(0...n).each do |i|` and do the work in the loop.")
          end

          def respond_to_missing?(name, include_private = false) = false

          private

          def last
            Counts.refuse_endless!("range") if @from.nil? || @upto.nil?
            @exclusive ? @upto - 1 : @upto
          end
        end
      end
    end
  end
end
