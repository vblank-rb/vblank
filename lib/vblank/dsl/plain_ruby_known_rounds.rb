# frozen_string_literal: true

module VBlank
  module DSL
    module PlainRuby # :nodoc: all
      module Counts
        # A counted Ruby loop whose count is known while building, `16.times { |i| ... }` or
        # `0.upto(7)`, in game code: written out once a round, or made one loop the game runs.
        #
        # Ruby runs the loop while building, as it always has, and each round records its
        # statements. Then the build chooses, by size alone, so the same game always builds the
        # same way:
        #
        # - Written out while all the rounds together hold at most WRITTEN_OUT_MOST IR nodes. A
        #   round written out runs no loop of its own (no count to keep, no test, no jump back),
        #   which for a small body is a large share of the work; and a few small rounds cost the
        #   cartridge little.
        # - Made one loop past that, where the rounds are alike: each round is the first with
        #   only its whole numbers changed, each by the same step from round to round. The loop
        #   is the first round, each such number worked out from the loop's count, and costs one
        #   round of room however many rounds there are. It costs time each round that rounds
        #   written out do not: counting the round and going back, and a multiply and an add for
        #   each number worked out (#make_loop! says why not a running number).
        # - Written out however large, where the rounds differ in anything else: a picture
        #   named from the round number, a colour picked from a table while building, a test
        #   on the round number decided while building, a name made in one round alone. The
        #   round number had to be known while building there, and only the rounds written out
        #   have it.
        #
        # Ruby has already run every round, so what plain Ruby keeps (an Array filled while
        # building, a name counted up) is right whichever is chosen: only the game's statements
        # change. Every choice is kept for `rom.profile` (Diagnostics::CountedLoops).
        #
        # A loop with a `break` or `next` in it is left written out, as Ruby ran it.
        class KnownRounds
          # The most IR nodes a counted loop's rounds may hold together and still be written out.
          # A round of two `draw_rect_at` lines is ten, so four such rounds are written out and
          # seven are a loop.
          WRITTEN_OUT_MOST = 64

          # A loop counter the build named, which each round of a loop inside a round has its own
          # of: the rounds are alike where each uses its own in the same places.
          LOOP_COUNTER = /\A__repeat_\d+\z/

          # Runs Ruby's loop, which the block runs given the round's own block, recording
          # +body+'s rounds; then writes them out or makes them a loop. Hands back what Ruby's
          # loop gave.
          def self.run(builder, body)
            outer = Thread.current[DEPTH] || 0
            rounds = new(builder, inside_another: outer.positive?)
            Thread.current[DEPTH] = outer + 1
            given =
              begin
                yield(proc { |*numbers| rounds.record { body.call(*numbers) } })
              ensure
                Thread.current[DEPTH] = outer
              end
            rounds.choose!
            given
          end

          # How many counted loops are recording rounds around the one starting, on this thread.
          DEPTH = :vblank_known_rounds_depth

          # +inside_another+: this loop is in a round of another counted loop, whose rounds are
          # alike only where this loop's numbers are worked out the same way in each
          # (ChangingNumber#worked_out_from).
          def initialize(builder, inside_another: false)
            @builder = builder
            @inside_another = inside_another
            @mark = builder.statement_mark
            @source = Messages::AuthorSource.author_source
            @rounds = []
          end

          # Runs one round, keeping what it recorded after the rounds before it. A round that took
          # back a statement of the rounds before leaves them unlike what is recorded, which
          # #still_recording_here? sees.
          def record
            before = recorded.size
            given = yield
            @rounds << recorded.drop(before)
            @notes_after_first ||= @builder.counted_loop_notes.size
            given
          end

          def choose!
            return unless still_recording_here?

            size = @rounds.sum { |round| round.sum { |statement| statement.walk.count } }
            return if @rounds.size < 2 || size.zero?
            return note(:written_out, size) if size <= WRITTEN_OUT_MOST

            alike = RoundsAlike.new(@rounds)
            return note(:rounds_differ, size) unless alike.alike?

            worked_out = make_loop!(alike)
            note(:loop, size, worked_out: worked_out)
          end

          private

          def note(choice, size, worked_out: 0)
            @builder.record_counted_loop(VBlank::Builder::CountedLoopNote.new(source: @source, rounds: @rounds.size,
                                                                              written_size: size, choice: choice,
                                                                              worked_out: worked_out))
          end

          # The statements recorded since the loop began.
          def recorded
            children = @mark.container.children
            start = @mark.last ? children.index { |statement| statement.equal?(@mark.last) } : -1
            start ? children[(start + 1)..] : []
          end

          # Does the builder record where the loop began, and is everything there a round's? A
          # round that moved or took back a statement recorded before it leaves the rounds as Ruby
          # wrote them.
          def still_recording_here?
            return false unless @builder.statement_mark.container.equal?(@mark.container)

            all = recorded
            flat = @rounds.flatten
            all.size == flat.size && all.zip(flat).all? { |statement, kept| statement.equal?(kept) }
          end

          # The first round in a loop of as many rounds, each changing number worked out from the
          # loop's count. The other rounds are dropped, with what they alone made: their loop
          # counters and the notes of counted loops inside them. Hands back how many numbers are
          # worked out.
          #
          # Why not a running number, set before the loop and stepped by an add at the end of
          # each round, as a console game walks a table? Measured on the Advance it costs more
          # than this does: the loop's count sits in a register (GBA::LoopForm) where a multiply
          # and an add on it are two instructions, while a running number is a variable in memory,
          # loaded where it is read and loaded, added to and stored again each round. It would
          # win only where a lowering keeps the running number in a register too.
          def make_loop!(alike)
            index = @builder.declare_loop_counter
            alike.changing_numbers.each do |number|
              number.node.parent.replace_operand(number.node, number.worked_out_from(index, whole: @inside_another))
            end
            @builder.take_statements_since(@mark)
            @builder.record_statement(IR::Build.repeat(@rounds.size, index, *@rounds.first))
            alike.later_names.each { |name| @builder.forget_loop_counter(name) }
            @builder.drop_counted_loops_after(@notes_after_first)
            alike.changing_numbers.size
          end
        end

        # A whole number of the first round that changes from round to round, by +step+ each time.
        ChangingNumber = Data.define(:node, :first, :step) do
          # The number in the round counted +index+ (from 0): first + step * index. A step of 1 and
          # a first of 0 are left out, unless +whole+ asks for the sum written in full: a loop in
          # the round of another counted loop, whose rounds differ in those two numbers and must
          # still be alike.
          def worked_out_from(index, whole: false)
            round = IR::Build.var_ref(index)
            sum = step == 1 && !whole ? round : IR::Build.binop(:*, round, IR::Build.int(step))
            first.zero? && !whole ? sum : IR::Build.binop(:+, sum, IR::Build.int(first))
          end
        end

        # Are a counted loop's rounds the first round with only whole numbers changed, each by one
        # step a round? Each round's statements are walked side by side: every node of one kind,
        # every operand and name the same, but for a number (an `int` node standing directly in an
        # operand, where an expression can stand instead) and the loop counters each round's own
        # loops count in. A declaration in a round is never alike: it is made once, not each round.
        class RoundsAlike
          attr_reader :changing_numbers

          def initialize(rounds)
            @rounds = rounds
            @changing_numbers = []
            @counters = rounds.map { {} }
            @counters_back = rounds.map { {} }
          end

          def alike? = parts_alike?(@rounds)

          # The loop counters of every round but the first, which the loop does not keep.
          def later_names = @counters.drop(1).flat_map(&:keys).reject { |name| @counters.first.key?(name) }

          private

          def parts_alike?(parts)
            head = parts.first
            case head
            when IR::Node then nodes_alike?(parts)
            when Array then arrays_alike?(parts)
            when Symbol then names_alike?(parts)
            else parts.all? { |part| part.eql?(head) }
            end
          end

          def arrays_alike?(parts)
            head = parts.first
            parts.all? { |part| part.is_a?(Array) && part.size == head.size } &&
              head.each_index.all? { |at| parts_alike?(parts.map { |part| part[at] }) }
          end

          def nodes_alike?(parts)
            head = parts.first
            return false unless parts.all? { |part| part.instance_of?(head.class) }
            return false unless %i[statement value].include?(head.class.role)
            return numbers_alike?(parts) if head.kind == :int

            fields = head.attrs.keys
            parts.all? { |part| part.attrs.keys == fields } &&
              fields.all? { |field| parts_alike?(parts.map { |part| part.attrs[field] }) } &&
              parts_alike?(parts.map(&:children))
          end

          def numbers_alike?(parts)
            values = parts.map(&:value)
            return true if values.uniq.size == 1
            return false unless values.all?(Integer) && in_operand?(parts.first)

            first = values.first
            step = values[1] - first
            return false unless values.each_with_index.all? { |value, round| value == first + (step * round) }

            @changing_numbers << ChangingNumber.new(node: parts.first, first: first, step: step)
            true
          end

          def in_operand?(node) = node.parent&.attrs&.any? { |_field, held| held.equal?(node) }

          # The same name in every round, or each round's own loop counter in the same places.
          def names_alike?(parts)
            head = parts.first
            return parts.all? { |part| part == head } unless loop_counter?(head)

            parts.each_with_index.all? do |name, round|
              loop_counter?(name) &&
                (@counters[round][name] ||= head) == head && (@counters_back[round][head] ||= name) == name
            end
          end

          def loop_counter?(name) = name.is_a?(Symbol) && Counts::KnownRounds::LOOP_COUNTER.match?(name)
        end
      end
    end
  end
end
