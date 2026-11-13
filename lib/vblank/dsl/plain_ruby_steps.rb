# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby
      # What a rewritten game block calls as it runs (see PlainRuby). Each step looks at the value
      # it is handed: a test the game makes as it plays records game code, and anything else does
      # just what Ruby would.
      module Steps
        MOST_PASSES = IR::Guardrails::Checks::LoopNeverWaits::MOST_PASSES

        # Bits on numbers, and on tests a join with both sides worked out.
        BIT_JOINS = %i[& | ^].freeze

        module_function

        # Truthiness is Ruby's. Only a test, or a yes or no the game keeps, has an answer that waits
        # for the game to play. Every other value is answered here: nil and false are falsy, and
        # everything else is truthy, a number of the game's among them, whatever it holds.
        def game_test?(value) = value.is_a?(Condition) || (value.is_a?(Value) && (value.boolean? || !value.truth.nil?))

        # Does this name a place that keeps a number, rather than a working-out of one?
        def variable?(value) = value.is_a?(Value) && value.handle?

        # Can a game variable start with this?
        def game_value?(value) = [Integer, Float, Symbol, TrueClass, FalseClass].any? { |kind| value.is_a?(kind) }

        def as_condition(value)
          return value unless value.is_a?(Value)

          value.truth ? value.truth == Value::TRUTHY_HELD : value != 0
        end

        # `a == b`. Ruby asks the left side. A plain number, symbol or yes or no asked whether it
        # equals a number the game keeps answers for itself, true or false, while the game is built:
        # Ruby's own `3 == hp` is true whatever hp holds, and a loop that starts `until row == rows`
        # with row still a plain 0 would never run. So that one is asked of the game's number, the
        # other way round, which makes the test the game asks as it plays.
        def equal_test(left, right) = plain_beside_game_number?(left, right) ? right == left : left == right

        # `a != b`, the same way.
        def unequal_test(left, right) = plain_beside_game_number?(left, right) ? right != left : left != right

        def plain_beside_game_number?(left, right) = game_value?(left) && right.is_a?(Value)

        # `x.nil?`. A name that keeps what it holds is asked as the game plays.
        def nil_test(value) = value.is_a?(Value) && value.truth ? value.truth == Value::NIL_HELD : value.nil?

        # A conditional's test, as an object the rewritten `if` asks which sides to run. A number
        # worked out for it is truthy and used for nothing more, so no check counts it as dropped.
        def branch_test(value)
          return GameTest.new(as_condition(value)) if game_test?(value)

          value.discard! if value.is_a?(Value)
          BuildTest.new(value)
        end

        # The other answer to a test, for `!` and `unless`.
        def opposite(value)
          return !value unless value.is_a?(Value) && game_test?(value)

          value.truth ? value.truth != Value::TRUTHY_HELD : value == 0
        end

        # `&&`. Two tests that only compare numbers join into one, both worked out as the game
        # plays, which nobody can tell from Ruby's skipping of the right side. A right side that
        # does something, or reads a list, is really skipped (see #side_under). +used+ is false
        # for a join standing alone as a statement, whose answer nothing reads.
        def join_both(left, used: true, into: nil)
          return left && yield unless game_test?(left)

          condition = as_condition(left)
          right, if_node = side_under(condition) { yield }
          return keep_side_answer(condition, if_node, right, otherwise: 0, used: used, into: into) if if_node
          return condition & as_condition(right) if game_test?(right)

          right ? condition : condition.discard!
        end

        # `||`, the same way round.
        def join_either(left, used: true, into: nil)
          return left || yield unless game_test?(left)
          return number_or_other_side(left) { yield } if left.is_a?(Value) && left.truth

          condition = as_condition(left)
          unless_left = !condition
          right, if_node = side_under(unless_left) { yield }
          return keep_side_answer(unless_left, if_node, right, otherwise: 1, used: used, into: into) if if_node
          return condition | as_condition(right) if game_test?(right)

          right ? condition.discard! || right : condition
        end

        # The subject of a `case ... in` whose patterns Ruby matches while building. See
        # Rewriter#case_match_text.
        def plain_pattern_subject(subject)
          return subject unless subject.is_a?(Value) || subject.is_a?(Condition)

          refuse_game_code!("This `case ... in` asks about a number the game keeps. The game can match that number " \
                            "only against numbers, ranges, symbols and constants, with `|` between them. To fix " \
                            "this, write one of those after `in`. Or write tests with `case ... when`: `case` with " \
                            "no subject, then `when hp > 3 then`.")
        end

        # A piece put into a String or a Symbol with `#{...}`. See Rewriter#embedded_text.
        def text_piece(piece)
          return piece unless piece.is_a?(Value) || piece.is_a?(Condition)

          refuse_game_code!("This text puts a game number into a String with `\#{...}`. Ruby makes the String " \
                            "once, while it builds the game. The number changes as the game plays, so the String " \
                            "cannot show it. To fix this, draw the words and the number apart: " \
                            "`draw_text \"HP\", 8, 8, :white`, then `draw_number hp, 32, 8, :white`. If the text " \
                            "is a name made in a loop, count with Ruby's `3.times { |i| ... }`, not `repeat`.")
        end

        # The range of `for x in a..b`, which Ruby runs while building. See Rewriter#for_text.
        def for_range(from, upto, exclusive)
          if [from, upto].any?(Value)
            refuse_game_code!("A `for` loop cannot count from or to a number the game keeps. Ruby runs a `for` loop " \
                              "while it builds the game. To fix this, use a `while` loop. Write `i = 0`, then " \
                              "`while i < n`, and end the loop's body with `i += 1`.")
          end
          Range.new(from, upto, exclusive)
        end

        # What `for x in things` goes over, which Ruby runs while building. See Rewriter#for_text.
        def for_collection(collection)
          return collection unless collection.is_a?(List) || collection.is_a?(Pool)

          refuse_game_code!("A `for` loop cannot go over a list or a pool. Ruby runs a `for` loop while it builds " \
                            "the game, and the game holds the items. To fix this, use `.each`: write " \
                            "`things.each do |thing|`.")
        end

        # One `when`: does +subject+ match any of +choices+? A plain subject is Ruby's to answer. A
        # number the game keeps becomes a test, one choice at a time.
        def when_test(subject, *choices)
          return choices.any? { |choice| choice === subject } unless subject.is_a?(Value) || subject.is_a?(Condition) # rubocop:disable Style/CaseEquality

          refuse_game_code!("`case` cannot ask about a test the game makes. To fix this, write `if`.") if subject.is_a?(Condition)

          choices.map { |choice| test_of_choice(subject, choice) }.reduce(:|)
        end

        def test_of_choice(subject, choice)
          case choice
          when Integer, Symbol, Value then subject == choice
          when true then subject == 1
          when false then subject == 0
          when Range then test_of_range(subject, choice)
          else refuse_game_code!("`when #{choice.inspect}` cannot be asked of a number the game keeps. A game " \
                                 "can compare a number, a symbol, a range or a variable.")
          end
        end

        def test_of_range(subject, range)
          below_top = range.exclude_end? ? subject < range.end : subject <= range.end
          (subject >= range.begin) & below_top
        end

        # `target || 7` on a name that may hold nil: its number if it is truthy, and the right side
        # if not, picked the way `x = test ? a : b` picks.
        def number_or_other_side(left)
          test = GameTest.new(as_condition(left))
          test.open_yes_side
          test.keep_side_value(number_of(left))
          test.open_no_side
          test.keep_side_value(yield)
          test.picked_value
        end

        # The number alone, which no longer counts as a test.
        def number_of(value) = value + 0

        # The left side of `found or next`, as Ruby would answer it. A test the game makes has no
        # answer yet, and a jump needs one now.
        def answer_before_jump(value, word)
          refuse_jump!(word) if game_test?(value)

          !!value
        end

        # The right side of `&&` or `||`, worked out under +condition+, and the branch it is in when
        # that branch must stay, still open: the side did something the game does, a sound or a
        # change, or reads a list at a place the left may have ruled out. If it only made a test,
        # nothing is left of the branch and the two tests join.
        def side_under(condition)
          if_node = condition.open_branch
          right = yield
          return [right, if_node] unless if_node.children.empty? && !reads_list?(right)

          condition.close_branch
          condition.take_back_branch(if_node)
          [right, nil]
        end

        # A slot at a place worked out as the game plays. One past the end stops the game. A pool
        # keeps its fields in lists too, read at a row that `each` handed over, always a real one.
        def reads_list?(value)
          return false unless value.is_a?(Condition) || value.is_a?(Value)

          value.node.walk.any? do |node|
            next false unless node.kind == :list_get && Messages::MadeNames.read(node.name)&.first != :pool_field

            node.index.walk.any? { |each_node| each_node.kind == :var_ref }
          end
        end

        # Closes the branch #side_under left open. The join's answer is the right side's on that
        # side and +otherwise+ on the other, so it is kept: in +into+, the game variable it is going
        # to anyway, or else in a hidden variable.
        def keep_side_answer(condition, if_node, right, otherwise:, used:, into: nil)
          unless used
            forget_value(right)
            condition.close_branch
            return
          end

          answer = into || condition.hidden_variable(:join)
          answer.mark_boolean! unless into
          store_truthiness(answer, right)
          condition.close_branch
          condition.open_other_branch(if_node)
          answer.store!(otherwise)
          condition.close_branch
          answer
        end

        # A test's answer goes in as the game plays. Anything else counts by Ruby's truthiness.
        def store_truthiness(target, value)
          return Writes.store_in_variable(target, as_condition(value)) if game_test?(value)

          forget_value(value)
          target.store!(value ? 1 : 0)
        end

        def forget_value(value)
          value.discard! if value.is_a?(Value) || value.is_a?(Condition)
        end

        # `a & b`, `a | b` and `a ^ b`: bits on numbers, and Ruby's own on anything else. Between
        # tests they join, working out both sides as Ruby does for these on true and false. The
        # operator is the one the game wrote, applied as Ruby applies it (public_send, on purpose).
        def bits(left, operator, right)
          if game_test?(left) && game_test?(right)
            as_condition(left).public_send(operator, as_condition(right))
          elsif game_test?(left) then bits_beside_plain(as_condition(left), operator, right)
          elsif game_test?(right) && (left.nil? || left == true || left == false)
            bits_beside_plain(as_condition(right), operator, left)
          else left.public_send(operator, right)
          end
        end

        # A test beside a plain value, which counts by its truthiness and decides now.
        def bits_beside_plain(test, operator, plain)
          case operator
          when :& then plain ? test : test.discard!
          when :| then plain ? !test.discard! : test
          else plain ? !test : test
          end
        end

        def loop_while(&test) = LoopTest.new(test, stops_when: false)
        def loop_until(&test) = LoopTest.new(test, stops_when: true)

        # The left of a join whose right side changes a name, asked like an `if`'s test.
        class JoinSide
          attr_reader :value

          def initialize(value) = @value = value

          def game? = Steps.game_test?(@value)
          def hidden_variable(why, like: nil) = Steps.as_condition(@value).hidden_variable(why, like: like)
          def refuse_jump!(word) = Steps.refuse_jump!(word)
        end

        def side_of_join(value) = JoinSide.new(value)

        # A right side of `a, b = b, a`, kept before the writes reach what it reads.
        def number_now(value) = value.is_a?(Value) ? value.hidden_copy(:swap) : value

        # What a name was given, kept as it is on this line, since something it was worked out from
        # changes before it is read. A number needs no keeping.
        # +copy+ chooses whether +value+, when it is a game variable, gets a copy
        # (Rewriter#kept_answer_copy): :always, :never, or :numbers to copy only one normal Ruby
        # made for a name's number (`@seed`, named by `game_variables`), leaving one a `var` line
        # made, which the game passes around to change.
        def kept_answer(value, copy: :always)
          return value if variable?(value) && !copies_variable?(value, copy)
          return value.hidden_copy if value.is_a?(Value)
          return value unless value.is_a?(Condition)

          kept = value.hidden_variable(:copy)
          kept.mark_boolean!
          Writes.store_answer(kept, value)
          kept
        end

        def copies_variable?(variable, copy)
          case copy
          in :always then true
          in :never then false
          in :numbers then variable.made_with_no_var_line?
          end
        end

        # `old = hp`. While the game plays that must keep hp's number as it is now, where a plain
        # second name would follow hp when it changes.
        def copy_of_variable(value) = variable?(value) ? value.kept_copy : value

        def refuse_game_code!(message)
          raise Refused, "#{message}#{Messages::AuthorSource.at_author_line}"
        end

        # A test made while building: one side runs, as in plain Ruby, and its value is the answer.
        class BuildTest
          attr_reader :answer

          alias picked_value answer
          alias tail_value answer

          def initialize(value)
            @value = value
          end

          def game? = false
          def open_yes_side = !!@value
          def open_no_side = !@value
          def close_side(value) = @answer = value
          def keep_side_value(value) = @answer = value
          def keep_tail_value(value) = @answer = value
          def store_side(target, value) = @answer = Writes.give_variable(target, value)
          def refuse_jump!(_word) = nil
        end

        # A test the game makes as it plays. BOTH sides run, once each, to record their code into
        # the two arms of one branch.
        class GameTest
          def initialize(condition)
            @condition = condition
          end

          def game? = true
          def hidden_variable(why, like: nil) = @condition.hidden_variable(why, like: like)

          def open_yes_side
            @if_node = @condition.open_branch
            true
          end

          def open_no_side
            @other_side = true
            @condition.open_other_branch(@if_node)
            true
          end

          def close_side(_value) = @condition.close_branch
          def answer = nil

          # A side's value, for `x = test ? a : b`. There is no way to pick one of two numbers in
          # the game, so each side stores its number in one hidden variable.
          def keep_side_value(value)
            boolean = [true, false].include?(value) || value.is_a?(Condition)
            unless boolean || value.is_a?(Integer) || value.is_a?(Value)
              Steps.refuse_game_code!("A test made as the game plays can only choose between numbers, " \
                                     "or between `true` and `false`. This side is #{value.inspect}. A " \
                                     "game variable cannot hold that.")
            end
            @kept ||= @condition.hidden_variable(:picked)
            @kept.mark_boolean! if boolean || (value.is_a?(Value) && value.boolean?)
            Writes.store_in_variable(@kept, value)
            @condition.close_branch
          end

          # A ternary ending a method, which may be there for what its sides do. A side a game can
          # keep a value of keeps one. A verb's nil or a handle of its own leaves nothing to answer with.
          def keep_tail_value(value)
            value.nil? || !Writes.number_kept?(value) ? close_side(value) : keep_side_value(value)
          end

          def tail_value = @kept

          # A side of `x = test ? a : b` on a game variable: the number goes straight into x.
          def store_side(target, value)
            Writes.give_variable(target, value)
            @condition.close_branch
          end

          def picked_value
            return @kept if @other_side

            Steps.refuse_game_code!("`x = if ...` needs an `else`. Without one, x has no number when " \
                                   "the test fails, and a game has no nil. To fix this, add an `else`.")
          end

          def refuse_jump!(word) = Steps.refuse_jump!(word)
        end

        def refuse_jump!(word)
          refuse_game_code!("`#{word}` cannot leave code the game runs as it plays. This block only records " \
                  "what the game will do, so there is nothing to #{word} from yet. To fix this, " \
                  "put the test in the `if` or `while` around this code.")
        end

        # A `while` or `until`, whose test is asked again each time round. On a plain value that
        # is all it is. On a game test the body runs ONCE, recording itself into a loop in the
        # game, and the second asking closes that loop.
        class LoopTest
          def initialize(test, stops_when:)
            @test = test
            @stops_when = stops_when
          end

          # The block runs once it is known this is a game's loop, and before the loop opens.
          def go_round(&before_loop)
            return close_game_loop if @game_loop

            mark = statement_mark
            value = @test.call
            return @stops_when ? !value : !!value unless Steps.game_test?(value)

            open_game_loop(value, mark, &before_loop)
          end

          def game? = !@game_loop.nil?
          def hidden_variable(why, like: nil) = @game_loop.hidden_variable(why, like: like)

          def refuse_jump!(word)
            Steps.refuse_jump!(word) if @game_loop
          end

          private

          # A name given a variable by the block must be read as that variable from now on, in the
          # test too, or the loop would ask about the number it held before.
          #
          # What working the test out records (a read's check of its place, the answer of a join
          # whose right side does something) moves into the loop, to run on every round before the
          # test is asked: left before the loop it would run once, and the test would ask the same
          # answer for ever. +mark+ is where the test started recording.
          def open_game_loop(value, mark, &before_loop)
            @game_loop = stopping_test(value)
            if before_loop
              yield
              @game_loop.discard!
              mark = statement_mark
              @game_loop = stopping_test(@test.call)
            end
            @game_loop.open_repeat(MOST_PASSES, test_statements: take_statements_since(mark))
            true
          end

          # Where the builder in use records next, or nil with none: a plain Ruby loop outside a
          # game. The builder is kept with it, so the statements are taken from the one recording.
          def statement_mark
            @builder = VBlank::Builder.in_use
            @builder&.statement_mark
          end

          def take_statements_since(mark) = mark ? @builder.take_statements_since(mark) : []

          def stopping_test(value)
            held = Steps.as_condition(value)
            @stops_when ? held : !held
          end

          def close_game_loop
            @game_loop.close_repeat
            false
          end
        end
      end
    end
  end
end
