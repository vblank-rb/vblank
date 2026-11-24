# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
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
        #
        # A thing `min` or `max` handed back is one too: whether the Array held any thing, as
        # Ruby's nil for an empty one is falsy (StructArray::Thing#found_test).
        def game_test?(value)
          return true if value.is_a?(StructArray::Thing) && value.found_flag

          value.is_a?(Condition) || (value.is_a?(Value) && (value.boolean? || !value.truth.nil?))
        end

        # Does this name a place that keeps a number, rather than a working-out of one?
        def variable?(value) = value.is_a?(Value) && value.handle?

        # Can a game variable start with this?
        def game_value?(value) = [Integer, Float, Symbol, TrueClass, FalseClass].any? { |kind| value.is_a?(kind) }

        def as_condition(value)
          return value.found_test if value.is_a?(StructArray::Thing) && value.found_flag
          return value unless value.is_a?(Value)

          value.truth ? value.truth == Value::TRUTHY_HELD : value != 0
        end

        # `a == b`. Ruby asks the left side. A plain number, symbol or yes or no asked whether it
        # equals a number the game keeps answers for itself, true or false, while the game is built:
        # Ruby's own `3 == hp` is true whatever hp holds, and a loop that starts `until row == rows`
        # with row still a plain 0 would never run. So that one is asked of the game's number, the
        # other way round, which makes the test the game asks as it plays.
        #
        # Two Arrays, where either holds a number the game keeps or is a list, are compared item by
        # item (#items_equal_test): Ruby's own Array#== would ask each pair with `==`, and a game
        # number answers that with a test, which Ruby counts as true whatever the numbers.
        def equal_test(left, right)
          return items_equal_test(left, right) if game_items_pair?(left, right)

          plain_beside_game_number?(left, right) ? right == left : left == right
        end

        # `a != b`, the same way.
        def unequal_test(left, right)
          return opposite(items_equal_test(left, right)) if game_items_pair?(left, right)

          plain_beside_game_number?(left, right) ? right != left : left != right
        end

        def plain_beside_game_number?(left, right) = game_value?(left) && right.is_a?(Value)

        # Are +left+ and +right+ two Arrays (a list among them) that Ruby's Array#== cannot
        # compare, since one holds a number the game keeps?
        def game_items_pair?(left, right)
          sides = [left, right]
          sides.all? { |side| side.is_a?(Array) || side.is_a?(List) } &&
            sides.any? { |side| side.is_a?(List) || holds_game_number?(side) }
        end

        def holds_game_number?(items) = items.any? { |item| item.is_a?(Value) || (item.is_a?(Array) && holds_game_number?(item)) }

        # Ruby's Array#== (or, +strict+, Array#eql?) of two Arrays holding numbers the game keeps,
        # or of a list and an Array: true or false where the sizes differ or a pair of plain items
        # decides it while building, and otherwise one test the game makes, every pair of items
        # equal. A list's size is known only as the game plays, so the list answers that itself
        # (List#items_equal_test).
        def items_equal_test(left, right, strict: false)
          return left.items_equal_test(right, strict: strict) if left.is_a?(List)
          return right.items_equal_test(left, strict: strict) if right.is_a?(List)
          return false unless left.length == right.length

          # By index: `zip` on a named Array (KeyedArray) is refused as a copy of its variables.
          joined_tests(left.each_index.map { |at| item_equal_test(left[at], right[at], strict: strict) })
        end

        # One pair of items, as Array#== (or #eql?) asks it.
        def item_equal_test(left, right, strict: false)
          return items_equal_test(left, right, strict: strict) if game_items_pair?(left, right)
          return false if strict && !same_kind_of_number?(left, right)
          return equal_test(left, right) if left.is_a?(Value) || right.is_a?(Value)

          strict ? left.eql?(right) : left == right
        end

        # Ruby's `1.eql?(1.0)` is false: a whole number and a fraction are never eql?, whatever
        # they hold. A number the game keeps is whole or a fraction while building.
        def same_kind_of_number?(left, right)
          kinds = [left, right].map { |side| side.is_a?(Value) ? (side.fraction? ? Float : Integer) : side.class }
          kinds.uniq.one? || kinds.none? { |kind| [Integer, Float].include?(kind) }
        end

        # Every answer in +answers+ (true, false, or a test the game makes) holding: false where a
        # plain one is false, true where all are, and otherwise the tests joined with `&`.
        def joined_tests(answers)
          tests, plain = answers.partition { |answer| game_test?(answer) }
          unless plain.all?
            tests.each { |test| as_condition(test).discard! }
            return false
          end
          return true if tests.empty?

          tests.map { |test| as_condition(test) }.reduce(:&)
        end

        # `x.nil?`. A name that keeps what it holds is asked as the game plays.
        def nil_test(value)
          return !value.found_test if value.is_a?(StructArray::Thing) && value.found_flag

          value.is_a?(Value) && value.truth ? value.truth == Value::NIL_HELD : value.nil?
        end

        # A conditional's test, as an object the rewritten `if` asks which sides to run. A game
        # number alone (`if floor`, `secret ? a : b`) is truthy, as any object is in Ruby: that is a
        # presence check on a value that may be nil (an option given or not), decided while
        # building, and it is what the author meant. It is used for nothing more, so no check
        # counts it as dropped.
        def branch_test(value)
          return GameTest.new(as_condition(value)) if game_test?(value)

          value.discard! if value.is_a?(Value)
          BuildTest.new(value)
        end

        # The other answer to a test, for `!` and `unless`.
        def opposite(value)
          return !value.found_test if value.is_a?(StructArray::Thing) && value.found_flag
          return !value unless value.is_a?(Value) && game_test?(value)

          value.truth ? value.truth != Value::TRUTHY_HELD : value == 0
        end

        # A game number standing alone as a loop's test: `x while left`, `x until left`, `while left
        # ... end`. Ruby's answer is that every number is true, 0 too, so the loop is plain Ruby,
        # run while building: a `while` is written out for ever and the build never ends, and an
        # `until` never runs its body. An `if` on the same number keeps Ruby's answer (#branch_test),
        # since a presence check there means something; a loop on an object that is always there
        # can only go round for ever. C's answer, "is not 0", is not given to it, since that is not
        # Ruby's: the words show the comparison instead. A number that can hold nil (`target =
        # nil`) is a test of its own (#game_test?), and so is a yes or no; neither reaches this.
        def refuse_number_as_loop_test!(value, written)
          return unless value.is_a?(Value) && !game_test?(value)

          number = written.nil? || written.match?(/\A[@\w.]+\z/) ? written || "n" : "(#{written})"
          refuse_game_code!("This loop's test is a number that the game keeps, `#{written || number}`, with no " \
                            "comparison. In Ruby, every number is true, 0 too. So a `while` on it never stops, " \
                            "and an `until` on it never runs. To fix this, compare the number. For a number " \
                            "that is not 0, write `#{number} != 0` or `#{number} > 0`. For 0, write `#{number} == 0`.")
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

          refuse_number_question_as_number!(left) if right
          right ? condition.discard! || right : condition
        end

        # `lives.nonzero? || 1` or `shown = lives.nonzero?`: Ruby's `nonzero?` hands back the
        # number or nil, and a game's number is never nil, so here it is only a test
        # (Value#nonzero?). Used as a number, it would be a yes or no.
        def refuse_number_question_as_number!(value)
          return unless value.is_a?(Condition) && value.number_question

          question = value.number_question
          refuse_game_code!("This line uses `#{question}` as a number. In Ruby, `#{question}` " \
                            "gives the number or nil. A number the game keeps is never nil, so here `#{question}` " \
                            "is only a test. To fix this, write the test in full: `lives != 0 ? lives : 1`.")
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

        # A String put together from +pieces+ (`"HP #{hp}"`, see Rewriter#interpolated_string_text),
        # as Ruby joins them. A number the game works out has no digits while building, so a piece
        # that is one makes words with a number in them (TextWithNumbers) that `draw_text` draws.
        def text_of(pieces)
          pieces.each { |piece| text_piece(piece) if game_test?(piece) }
          return pieces.map(&:to_s).join if pieces.none? { |piece| piece.is_a?(Value) || piece.is_a?(TextWithNumbers) }

          TextWithNumbers.new(pieces.flat_map do |piece|
            case piece
            when TextWithNumbers then piece.parts
            when Value then [piece]
            else [piece.to_s]
            end
          end)
        end

        # The range of `for x in a..b`. Ruby asks it for `each`, so a range on plain numbers runs
        # while building, and one with a number the game keeps at an end is a loop the game runs
        # (Counts.range). See Rewriter#for_text.
        def for_range(from, upto, exclusive, jumps = nil) = Counts.range(from, upto, exclusive, jumps)

        # What `for x in things` goes over, which Ruby runs while building. See Rewriter#for_text.
        def for_collection(collection, _jumps = nil)
          return collection unless collection.is_a?(List) || collection.is_a?(Pool)

          refuse_game_code!("A `for` loop cannot go over a list or a pool. Ruby runs a `for` loop while it builds " \
                            "the game, and the game holds the items. To fix this, use `.each`: write " \
                            "`things.each do |thing|`.")
        end

        # `value.is_a?(kind)`, `kind_of?` or `instance_of?` in game code. An Array the game keeps
        # (a list, a pool, an Array of Structs) is an Array to these, as Ruby's would be, though the
        # object holding it in the build is not one; anything else answers for itself.
        def kind_question(value, question, kind)
          if kept_array?(value)
            return question == :instance_of? ? kind == Array : Array <= kind || value.is_a?(kind)
          end

          case question
          when :instance_of? then value.instance_of?(kind)
          else value.is_a?(kind)
          end
        end

        # `Array === value` in game code, with a constant on the left: a kind question where the
        # constant is a class or module, and the constant's own `===` otherwise (a Range, say).
        def case_equality(kind, value)
          return kind_question(value, :kind_of?, kind) if kind.is_a?(Module)

          kind === value # rubocop:disable Style/CaseEquality
        end

        # `value.class` in game code: Array for an Array the game keeps, as Ruby's would answer.
        def class_of(value) = kept_array?(value) ? Array : value.class

        # Is +value+ an Array the game keeps, held in the build by an object of the DSL's?
        def kept_array?(value) = value.is_a?(List) || value.is_a?(Pool) || value.is_a?(StructArray)

        # One `when`: does +subject+ match any of +choices+? A plain subject is Ruby's to answer. A
        # number the game keeps becomes a test, one choice at a time.
        def when_test(subject, *choices)
          return choices.any? { |choice| kind_question(subject, :kind_of?, choice) } if kept_array?(subject) && choices.all?(Module)
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

        # A range with no start (`..2`) or no end (`4..`) tests only the side it has, as Ruby's
        # Range#=== does. `nil..nil` holds every number, so it is a test that always passes: the
        # number against itself.
        def test_of_range(subject, range)
          tests = []
          tests << (subject >= range.begin) unless range.begin.nil?
          tests << (range.exclude_end? ? subject < range.end : subject <= range.end) unless range.end.nil?
          return subject == subject if tests.empty? # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands

          tests.reduce(:&)
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

        # +jumps+ are the `break` and `next` words written in the loop's own body (Jumps).
        def loop_while(written = nil, jumps: nil, &test) = LoopTest.new(test, stops_when: false, written: written, jumps: jumps)
        def loop_until(written = nil, jumps: nil, &test) = LoopTest.new(test, stops_when: true, written: written, jumps: jumps)

        # How many rounds a loop Ruby runs while building may go before it is taken as one that
        # never stops. A loop that lays out a table or a row of sprites goes round a few thousand
        # times at most; one whose test can never fail would hang the build with no words.
        MOST_BUILD_ROUNDS = 1_000_000

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

        # What a plain local holds, as Ruby holds it, for a line Promotion#kept_copy could not
        # prove safe to leave as a working-out: a number in a hidden variable of its own, holding
        # the number of this line, where Promotion.copy says what is copied and what stays as it is.
        # +copy+ is :numbers or :every_variable, from Promotion#kept_copy.
        #
        # +name+ is the local's: a copy is that name's own (Writes.promote), so another name given
        # it later and then a number never writes it.
        #
        # +button_kept+ marks a line outside game code that keeps a button for game code to read
        # (Promotion#button_kept?), which the build warns of.
        def kept_answer(value, copy: :numbers, name: nil, button_kept: false)
          copied = copy_for_local(value, Promotion.copy(value, copy))
          return copied if copied.equal?(value)

          copied.owner_name = name
          copied.record_kept_button if button_kept
          copied
        end

        # A test's answer is kept as 1 or 0; any other number copied is the value's hidden copy.
        def copy_for_local(value, answer)
          return value unless answer.promoted?
          return value.hidden_copy unless answer.reason == :copy_of_test_answer

          kept = value.hidden_variable(:copy)
          kept.mark_boolean!
          Writes.store_answer(kept, value)
          kept
        end

        # `left <=> right` written in game code. On plain values it is Ruby's. With a number the
        # game works out on a side it is that number's sign against the other, a number the game
        # works out too (Value#sign_against). Two Arrays compare item by item, as Ruby's do.
        def compare(left, right)
          return compare_arrays(left, right) if left.is_a?(Array) && right.is_a?(Array) && (left + right).any?(Value)
          return left <=> right unless [left, right].any?(Value)
          return left.sign_against(right) if left.is_a?(Value)
          return -right.sign_against(left) if left.is_a?(Numeric)

          refuse_unknown_compare!
        end

        # `[a1, a2] <=> [b1, b2]`: the first pair decides, and each after it breaks the ties of
        # those before. Each pair's sign is -1, 0 or 1, so weighing the first twice the next, and
        # so on, keeps its lead, and the sign of the sum is the answer. The pairs are kept on it.
        def compare_arrays(left, right)
          refuse_unknown_compare! unless left.size == right.size && !left.empty?

          signs = left.zip(right).map { |one, other| compare(one, other) }
          refuse_unknown_compare! unless signs.all? { |sign| sign.is_a?(Value) || sign.is_a?(Integer) }
          weights = signs.each_index.map { |at| 1 << (signs.size - 1 - at) }
          sum = signs.zip(weights).map { |sign, weight| weight == 1 ? sign : sign * weight }.reduce(:+) # rubocop:disable Performance/Sum -- sum would add a 0 the game works out too
          answer = sum.is_a?(Value) ? sum.sign_against(0) : sum <=> 0
          answer.compared_pairs = signs.flat_map { |sign| sign.is_a?(Value) ? sign.compared_pairs.to_a : [] } if answer.is_a?(Value)
          answer
        end

        def refuse_unknown_compare!
          refuse_game_code!("`<=>` here compares a number the game works out with something that is not a number, " \
                            "or two Arrays of different sizes. To fix this, compare two numbers, or two Arrays of " \
                            "numbers of the same size.")
        end

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
          def open_yes_side = open_side(!!@value, :yes)
          def open_no_side = open_side(!@value, :no)

          def close_side(value)
            note_measured_side
            @answer = value
          end

          def keep_side_value(value) = @answer = value

          # A test on a plain flag (`if @open`, `unless @planned`) in game code, which Ruby decides
          # here, once. Whether that is right depends on what the flag guards (InstanceVariables::Uses,
          # #refuse_game_flags!): a once-guard keeps work that is built, and a game flag keeps what the
          # game does as it plays. The side Ruby runs is watched for statements recorded into the
          # game, and the answer is kept for the side where it is written (+site+). The side Ruby
          # skips is noted, and judged once the build is over by what that side recorded wherever
          # the build did run it; a side never run is taken to record game code, unless the source
          # shows it records nothing (+quiet_yes+, +quiet_no+). Nothing here depends on how the
          # build is run, so every run of a game gets one answer.
          def watch_flag(owner, label, current, site:, quiet_yes:, quiet_no:)
            builder = InstanceVariables.builder_watching_flag(owner, label, current)
            return unless builder

            @builder = builder
            (@watched ||= []) << InstanceVariables::FlagRead.new(owner: owner, label: label, current: current)
            @site = site
            @quiet_yes = quiet_yes
            @quiet_no = quiet_no
          end

          # The same for a test whose answer came from plain flags read some other way
          # (InstanceVariables.flag_reads_since): through a reader (`if door.open?`), or in a
          # test written for its value (`@open ? 1 : 0`, +picks+). A test that picks a value
          # decides what the game reads, whatever its sides record, so it is noted as one that
          # guards game code.
          def watch_flag_reads(reads, site:, quiet_yes:, quiet_no:, picks:)
            reads.each do |read|
              next InstanceVariables.note_flag_picks(read) if picks

              watch_flag(read.owner, read.label, read.current, site: site, quiet_yes: quiet_yes, quiet_no: quiet_no)
            end
          end

          private

          def open_side(taken, side)
            return taken unless @builder

            site = "#{@site}:#{side}"
            if taken
              @measured = [@builder.statement_mark, site]
            elsif !(side == :yes ? @quiet_yes : @quiet_no)
              @watched.each { |read| InstanceVariables.note_flag_side_skipped(read.owner, read.label, read.current, site) }
            end
            taken
          end

          def note_measured_side
            return unless @measured

            mark, site = @measured
            records = @builder.recorded_since?(mark)
            @watched.each do |read|
              InstanceVariables.note_flag_side_run(read.owner, read.label, read.current, site, records: records)
            end
            @measured = nil
          end

          public

          def keep_tail_value(value) = @answer = value
          def store_side(target, value) = @answer = Writes.give_variable(target, value)
          def refuse_jump!(_word) = nil
        end

        # A test the game makes as it plays. Both sides run, once each, to record their code into
        # the two arms of one branch.
        class GameTest
          def initialize(condition)
            @condition = condition
          end

          def game? = true
          def hidden_variable(why, like: nil) = @condition.hidden_variable(why, like: like)

          # A flag that turned out to be the game's (BuildTest#watch_flag): both sides run anyway.
          def watch_flag(*, **) = nil
          def watch_flag_reads(*, **) = nil

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

        # A `break` or `next` in a `begin ... end while` body, under +tests+. Its first round runs
        # before the loop's test, so it is no loop yet: under a test the game makes, refused.
        def refuse_jump_in_do_while!(word, tests)
          return unless tests.any?(&:game?)

          refuse_game_code!("`#{word}` is in a `begin ... end while` loop, under a test the game makes. The game " \
                            "runs the first round of that loop before the loop starts, so the `#{word}` has no " \
                            "loop to #{word} from. To fix this, write the loop as `loop do`, and end its body " \
                            "with `break unless` and the test: `loop do ... break unless i < n end`.")
        end

        # A `while` or `until`, whose test is asked again each time round. On a plain value that
        # is all it is. On a game test the body runs once, recording itself into a loop in the
        # game, and the second asking closes that loop.
        class LoopTest
          def initialize(test, stops_when:, written: nil, jumps: nil)
            @test = test
            @stops_when = stops_when
            @written = written
            @jumps = jumps && Jumps.new(jumps)
            @build_rounds = 0
          end

          # A `break` or `next` in this loop's own body (Jumps#jump!). True when Ruby makes it.
          def jump!(word, tests, with_value: false) = @jumps.jump!(word, tests, with_value: with_value)

          # The block runs once it is known this is a game's loop, and before the loop opens.
          def go_round(&before_loop)
            return close_game_loop if @game_loop

            mark = statement_mark
            value = @test.call
            Steps.refuse_number_as_loop_test!(value, @written)
            return build_round(value) unless Steps.game_test?(value)

            open_game_loop(value, mark, &before_loop)
          end

          def game? = !@game_loop.nil?
          def hidden_variable(why, like: nil) = @game_loop.hidden_variable(why, like: like)

          def refuse_jump!(word)
            Steps.refuse_jump!(word) if @game_loop
          end

          private

          # One round of a loop Ruby runs while building: its answer, as Ruby's `while` takes it.
          def build_round(value)
            goes_on = @stops_when ? !value : !!value
            refuse_endless_build_loop! if goes_on && (@build_rounds += 1) > MOST_BUILD_ROUNDS
            goes_on
          end

          def refuse_endless_build_loop!
            Steps.refuse_game_code!("This loop went round a million times while the game was built, and it " \
                                    "did not stop. Ruby runs a loop on plain values while it builds the game. " \
                                    "If the test is a number alone, the test is always true, because every " \
                                    "number is true in Ruby, 0 too. To fix this, compare the number: write " \
                                    "`n != 0` or `n > 0`.")
          end

          # A name given a variable by the block must be read as that variable from now on, in the
          # test too, or the loop would ask about the number it held before.
          #
          # What working the test out records (a read's check of its place, the answer of a join
          # whose right side does something) moves into the loop, to run on every round before the
          # test is asked: left before the loop it would run once, and the test would ask the same
          # answer for ever. +mark+ is where the test started recording. Where the block runs first,
          # the test is asked again after it, so what the first asking recorded is taken out and
          # dropped with its answer.
          def open_game_loop(value, mark, &before_loop)
            @game_loop = stopping_test(value)
            if before_loop
              take_statements_since(mark)
              yield
              @game_loop.discard!
              mark = statement_mark
              @game_loop = stopping_test(@test.call)
            end
            test_statements = take_statements_since(mark)
            test_statements = open_jumps(test_statements) if @jumps
            @game_loop.open_repeat(MOST_PASSES, test_statements: test_statements)
            @jumps&.start_round!
            true
          end

          # The loop stops on its own test, or once a `break` in it ran. A test that records
          # statements of its own (`while (calls += 1) < most`) runs them only while no `break`
          # has: Ruby does not ask the test again after one. Hands back those statements.
          def open_jumps(test_statements)
            @jumps.open_game!(@builder)
            leave = @jumps.leave_test
            return test_statements unless leave

            @game_loop |= leave
            test_statements.empty? ? [] : [@jumps.unless_left(test_statements)]
          end

          # Where the game being built records next, or nil with none: a plain Ruby loop outside a
          # game. The builder is kept with it, so the statements are taken from the one recording.
          def statement_mark
            @builder = VBlank::Builder::Session.builder
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
