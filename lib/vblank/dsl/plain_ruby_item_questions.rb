# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      # Ruby's questions about the items of a collection, asked in game code: `[a, b].max`,
      # `scores.count { |n| n > 5 }`, `[a, b].include?(7)`.
      #
      # Ruby answers each while building, by comparing items or asking a block's test. A number
      # the game works out has no answer then, and a test the game makes is always there, so
      # Ruby's answer came out wrong without a word: `[a, b].max` gave whichever was first. The
      # rewrite sends each such call here (Rewriter#call_text). On a collection of Ruby's own
      # that holds a game number, or whose block makes a test the game decides, the game works
      # the answer out as it plays (QUESTIONS); a question that needs a test's answer to pick
      # items out (`find`, `select`) is refused. Anything else is Ruby's, answered as before: a
      # collection of plain numbers, and the game's own Arrays, which answer for themselves.
      module ItemQuestions
        # The questions the game answers as it plays.
        QUESTIONS = %i[max min minmax count any? all? none? include?].freeze

        # The questions that pick items out by a block's test, refused where the test is the game's.
        PICKING = %i[find detect find_index select filter reject partition filter_map take_while drop_while
                     max_by min_by sort_by sum].freeze

        # Every name the rewrite sends here.
        VERBS = (QUESTIONS + PICKING).freeze

        module_function

        # +receiver+.+verb+(*given, &block), answered as Ruby would, worked out by the game where
        # Ruby could not.
        def ask(receiver, verb, *given, &block)
          return ruby_answer(receiver, verb, given, block) unless ruby_collection?(receiver)
          return ruby_answer(receiver, verb, given, block && refusing_game_tests(verb, block)) unless QUESTIONS.include?(verb)

          items = receiver.to_a
          # The test is asked of each item once, as Ruby asks it, and its answers are used from then on.
          answers = items.map { |item| block.call(item) } if block && TESTS.include?(verb)
          if game_numbers?(items + given) || answers&.any? { |answer| Steps.game_test?(answer) }
            return game_answer(items, verb, given, answers || block)
          end

          ruby_answer(receiver, verb, given, answers ? answers_in_turn(answers) : block)
        end

        # The questions whose block is a test of one item.
        TESTS = %i[count any? all? none?].freeze

        # An Array, a Range or a Hash of Ruby's: not one of the game's own collections.
        def ruby_collection?(receiver) = [Array, Range, Hash].any? { |kind| receiver.is_a?(kind) }

        # Is any of +values+ a number or a test the game works out as it plays?
        def game_numbers?(values) = values.any? { |value| value.is_a?(Value) || value.is_a?(Condition) }

        # A block giving +answers+ one after another, for Ruby to ask in the same order again.
        def answers_in_turn(answers)
          remaining = answers.dup
          ->(*) { remaining.shift }
        end

        # The question as Ruby asks it, by name.
        def ruby_answer(receiver, verb, given, block)
          case verb
          when :max then receiver.max(*given, &block)
          when :min then receiver.min(*given, &block)
          when :minmax then receiver.minmax(&block)
          when :count then receiver.count(*given, &block)
          when :any? then receiver.any?(*given, &block)
          when :all? then receiver.all?(*given, &block)
          when :none? then receiver.none?(*given, &block)
          when :include? then receiver.include?(*given)
          when :find, :detect then receiver.find(*given, &block)
          when :find_index then receiver.find_index(*given, &block)
          when :select, :filter then receiver.select(&block)
          when :reject then receiver.reject(&block)
          when :partition then receiver.partition(&block)
          when :filter_map then receiver.filter_map(&block)
          when :take_while then receiver.take_while(&block)
          when :drop_while then receiver.drop_while(&block)
          when :max_by then receiver.max_by(*given, &block)
          when :min_by then receiver.min_by(*given, &block)
          when :sort_by then receiver.sort_by(&block)
          when :sum then receiver.sum(*given, &block)
          end
        end

        # +block+, refusing a test the game decides: Ruby would pick items by an answer it does
        # not have yet.
        def refusing_game_tests(verb, block)
          lambda do |*item|
            answer = block.call(*item)
            refuse_picking_by_game_test!(verb) if Steps.game_test?(answer)
            answer
          end
        end

        # The game's answer to a QUESTIONS verb. +tested+ is what a test block gave for each item,
        # or the block of `max` and `min`, which the game does not take.
        def game_answer(items, verb, given, tested)
          refuse_given_for!(verb, given) unless given.empty? || %i[include? count].include?(verb)
          refuse_given_for!(verb, ["a block"]) if tested.is_a?(Proc)
          answers = tested || items
          case verb
          when :max then most(items, :>)
          when :min then most(items, :<)
          when :minmax then [most(items, :<), most(items, :>)]
          when :include? then how_many(items.map { |item| item == given.first }) > 0
          when :count
            return items.length if given.empty? && tested.nil?

            how_many(given.empty? ? answers : items.map { |item| item == given.first })
          when :any? then how_many(answers) > 0
          when :all? then how_many(answers) == items.length
          when :none? then how_many(answers) == 0
          end
        end

        # The item that wins every +compare+ (`:>` for the biggest), the first of those level, kept
        # in a hidden number: one compare and pick for each item after the first.
        def most(items, compare)
          return items.first if items.length < 2

          builder = Builder::Session.builder
          kept = builder.hidden_variable(:picked, like: items.find { |item| item.is_a?(Value) || item.is_a?(Float) })
          kept.store!(items.first)
          items.drop(1).each do |item|
            beats = compare == :> ? kept < item : kept > item
            beats.record_branch { kept.store!(item) }
          end
          kept
        end

        # How many of +answers+ hold, a test at a time, kept in a hidden number. An answer known
        # while building counts then.
        def how_many(answers)
          counted = Builder::Session.builder.hidden_variable(:counted)
          counted.store!(answers.count { |answer| answer && !Steps.game_test?(answer) })
          answers.select { |answer| Steps.game_test?(answer) }.each do |answer|
            Steps.as_condition(answer).record_branch { counted.increase!(1) }
          end
          counted
        end

        def refuse_picking_by_game_test!(verb)
          Steps.refuse_game_code!("`#{verb}` picks items by a test, and this test is decided as the game plays. " \
                                  "Ruby needs the answer while the game is built. To fix this, walk the items with " \
                                  "`each` and keep what the test finds in a game number.")
        end

        def refuse_given_for!(verb, given)
          Steps.refuse_game_code!("`#{verb}(#{given.map(&:inspect).join(', ')})` on game numbers is not one the game " \
                                  "can answer. To fix this, write `#{verb}` with no arguments.")
        end
      end
    end
  end
end
