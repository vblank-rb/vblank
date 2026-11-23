# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # Ruby's counting loops, `n.times`, `a.upto(b)`, `a.downto(b)`, `a.step(b, by)`, a range's
      # `each` and `step`, and `for x in a...b`, as a rewritten game block calls them, and
      # `loop do` with a `break` in it.
      #
      # On plain numbers each is Ruby's own and runs while building, written out once a round.
      # Where a number at either end is one the game keeps, nobody knows while building how many
      # rounds there are, so the loop is one the game runs as it plays (Builder#repeat): it goes
      # round as many times as Ruby's would, handing the block each number Ruby would hand it.
      # Ruby reads the start and the count once, as the loop begins, and so does the game's loop.
      #
      # A loop whose body holds a `break` or a `next` is handed its Jumps, which the game's loop
      # opens (Jumps#open_game!) and a loop Ruby runs leaves to Ruby.
      module Counts
        module_function

        # What `n.times { }` and its kin are asked of. A number, plain or the game's, answers
        # through a Start; anything else is left to answer for itself.
        def start(value, jumps = nil) = value.is_a?(Integer) || value.is_a?(Value) ? Start.new(value, jumps) : value

        # The range of `(a...b).each { }` or `for x in a...b`: Ruby's own on plain numbers, its
        # rounds written out or made a loop (KnownRange).
        def range(from, upto, exclusive, jumps = nil)
          return GameRange.new(from, upto, exclusive, jumps) if [from, upto].any?(Value)
          return Range.new(from, upto, exclusive) if jumps

          KnownRange.new(from, upto, exclusive)
        end

        # Ruby's own loop, which the block runs given the round's block, on numbers known while
        # building: in game code with no `break` or `next`, its rounds are written out or made a
        # loop (KnownRounds); anywhere else it is only Ruby's.
        def known_rounds(jumps, body, &ruby_loop)
          builder = VBlank::Builder.in_use
          return ruby_loop.call(body) if jumps || builder.nil? || body.nil?

          KnownRounds.run(builder, body, &ruby_loop)
        end

        # A Ruby range of plain numbers whose `each` and `step` with a block are counted loops
        # (Counts.known_rounds). Everything else is Range's own.
        class KnownRange < Range
          def each(&body) = body ? Counts.known_rounds(nil, body) { |round| super(&round) } : super

          def step(*given, &body) = body ? Counts.known_rounds(nil, body) { |round| super(*given, &round) } : super
        end

        # `loop do ... end` with a `break` in it. It is Ruby's, its rounds run while building,
        # until a jump in it sits under a test the game makes (Jumps#note_round_start!). That
        # round is the last Ruby writes out; the rounds after it are a loop the game runs, which
        # only that `break` leaves, as in Ruby.
        #
        # A loop Ruby ends, by a `break` or by an enumerator in it running out (StopIteration,
        # which Ruby's `loop` ends on and hands back the result of), ends here the same way.
        #
        # The game's rounds are one more recording of the block, which must record what the
        # switching round did: a plain value that changed between the two (`steps.next`) would
        # be kept at one round's number for ever, so that is refused (#refuse_changing_round!).
        def endless(jumps, &)
          builder = VBlank::Builder.in_use
          rounds = 0
          ended = loop do
            jumps.note_round_start!(builder) if builder
            yield
            break :game if jumps.game?

            refuse_endless_build_loop! if (rounds += 1) > Steps::MOST_BUILD_ROUNDS
          end
          return ended unless jumps.game?

          refuse_changing_round! unless ended == :game

          game_rounds_after_switch(builder, jumps, &)
          nil
        end

        def game_rounds_after_switch(builder, jumps)
          switched = jumps.round_statements
          jumps.end_round!
          builder.repeat(Steps::MOST_PASSES, stop_when: jumps.leave_test) do
            jumps.start_round!
            begin
              yield
            rescue StopIteration
              refuse_changing_round!
            end
            jumps.end_round!
          end
          refuse_changing_round! unless RoundShape.same?(switched, jumps.round_body(builder.last_recorded_statement))
        end

        # Do two recordings of one block do the same? Each statement's kind, operands and the
        # statements inside it must match, numbers and names alike, except the names the build
        # makes for itself (`__...`), which each recording makes afresh: those must only stand in
        # the same places.
        module RoundShape
          module_function

          def same?(one, other) = shape(one, {}) == shape(other, {})

          def shape(part, names)
            case part
            when IR::Node then [part.kind, part.attrs.map { |field, held| [field, shape(held, names)] },
                                part.children.map { |child| shape(child, names) }]
            when Array then part.map { |each_part| shape(each_part, names) }
            when Symbol then part.start_with?("__") ? (names[part] ||= names.size) : part
            else part
            end
          end
        end

        def refuse_changing_round!
          Steps.refuse_game_code!("This `loop do` is a loop the game runs, since a `break` or `next` in it is under a " \
                                  "test the game makes. But its body reads a plain Ruby value that changes on each " \
                                  "round, such as `steps.next`. The game keeps one round's value only. To fix this, " \
                                  "read the values from an Array the game keeps, at a number the game counts.")
        end

        def refuse_endless_build_loop!
          Steps.refuse_game_code!("This `loop do` went round a million times while the game was built, and no " \
                                  "`break` left it. Ruby runs a loop on plain values while it builds the game. " \
                                  "To fix this, give the `break` a test that can hold.")
        end

        def game?(*values) = values.any?(Value)

        # Goes round +rounds+ times as a loop the game runs, handing the block +first+, then
        # +first+ plus +by+, and so on. +first+ must not change while the loop runs (#held).
        def game_loop(first, rounds, by, jumps)
          game_rounds(VBlank::Builder.in_use, rounds, jumps) do |index|
            number = by == 1 ? index : index * by
            number += first unless first.is_a?(Integer) && first.zero?
            yield number
          end
        end

        # At most +rounds+ rounds of a loop the game runs, each handed its count from 0.
        def game_rounds(builder, rounds, jumps)
          jumps&.open_game!(builder)
          builder.repeat(rounds, stop_when: jumps&.leave_test) do |index|
            jumps&.start_round!
            yield index
            jumps&.end_round!
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
          def initialize(start, jumps = nil)
            @start = start
            @jumps = jumps
          end

          def times(&body)
            return Counts.known_rounds(@jumps, body) { |round| @start.times(&round) } unless Counts.game?(@start)

            Counts.game_loop(0, @start, 1, @jumps, &body)
            @start
          end

          def upto(last, &body)
            return Counts.known_rounds(@jumps, body) { |round| @start.upto(last, &round) } unless Counts.game?(@start, last)

            first = Counts.held(@start)
            Counts.game_loop(first, last - first + 1, 1, @jumps, &body)
            @start
          end

          def downto(last, &body)
            return Counts.known_rounds(@jumps, body) { |round| @start.downto(last, &round) } unless Counts.game?(@start, last)

            first = Counts.held(@start)
            Counts.game_loop(first, first - last + 1, -1, @jumps, &body)
            @start
          end

          # `a.step(limit, by)` or `a.step(by:, to:)`. Ruby's rounds are every number from the
          # start to the limit, +by+ apart. Adding +by+ before dividing counts the start itself,
          # and gives no rounds for a limit behind the start, whichever way the divide rounds.
          def step(*given, **options, &body)
            unless Counts.game?(@start, *given, *options.values)
              return Counts.known_rounds(@jumps, body) { |round| @start.step(*given, **options, &round) }
            end

            limit = options.fetch(:to, given[0])
            by = options.fetch(:by, given[1] || 1)
            Counts.refuse_unknown_step!(by)
            Counts.refuse_endless!("step") if limit.nil?
            first = Counts.held(@start)
            rounds = by.positive? ? (limit - first + by) / by : (first - limit - by) / -by
            Counts.game_loop(first, rounds, by, @jumps, &body)
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
          def initialize(from, upto, exclusive, jumps = nil)
            @from = from
            @upto = upto
            @exclusive = exclusive
            @jumps = jumps
          end

          def each(&)
            Start.new(@from, @jumps).upto(last, &)
            self
          end

          def step(by, &)
            Start.new(@from, @jumps).step(last, by, &)
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
