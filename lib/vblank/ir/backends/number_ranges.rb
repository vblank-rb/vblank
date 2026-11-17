# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # WHAT RANGE A NUMBER STAYS IN, worked out from the program before anything is lowered.
      #
      # Every number is 32 bits (IR::Int32), and every backend gives Int32's answers. But most of
      # what a game keeps is small: a place on a screen of 240 pixels, a slot of a list of bytes, a
      # count masked to 31, an entry of a table of steps. A console whose processor works 8 or 16
      # bits at a time pays two or four times the work for the bits above, which hold nothing but
      # the sign. Where the build can prove a number stays in 8 or 16 bits, a lowering can work it
      # at that width and still give Int32's answer, since the bits it leaves out are only the sign
      # spread upward. This says which numbers those are; each lowering decides what to do with it.
      #
      # A VALUE's range comes from what it is made of: numbers written in the program, a slot of a
      # list (it keeps the slot's low bits and reads them back with their sign,
      # Reference::ListValue), a list's length (no more than its capacity), an entry of a table (the
      # table never changes), a comparison (1 or 0), a mask, a remainder, a shift, and sums,
      # differences and products of those, each only where Int32's answer cannot wrap.
      #
      # A VARIABLE's range is proven, conservatively: it is a byte (or two) when every statement
      # that names it is a read of it, or a write this can bound, and every write is proven to land
      # in that range. The proof assumes the variables it names are in range too, and drops any
      # whose write it cannot prove, over and over until none drops (the largest set that proves
      # itself): a variable starts at nought, and each write keeps it in range as long as what it
      # reads was, so by induction over the run every one stays in range. A write is proven when it is
      #
      # - `set` to a value whose range is proven;
      # - `copy` from a variable in range;
      # - `clamp` between bounds in range (Reference#exec_clamp holds it at the floor, then the
      #   ceiling, which can only move it toward them);
      # - a `repeat`'s turn number, for a count proven in range;
      # - `add` or `sub` of a number written in the program, just after a `list_set` at the
      #   variable in the same block with nothing between that can change it: the write to the
      #   list stops the game unless the variable is a slot of it, so after the sum it is within
      #   the list's capacity, moved by that number (a counter filling a list);
      # - the one more ending a counted while (Backends::LoopForm#counted_while), to a limit in
      #   range: the loop asks that the variable is below the limit before each turn and nothing
      #   else in it writes either, so the sum is at most the limit.
      #
      # NOT proven: a variable any other statement names (a save, a timer, a `case`, an `every`),
      # the frame's own counters, ones the caller names (+also_whole+: written by the lowering
      # itself, as a game loop's own numbers are), the `negate` and `abs` statements (the lowest
      # number of a range turned round is one past its highest), and a sum with no list holding it in. One the game declared narrow (IR::KeptWidths) is in its
      # width wherever it is read, since the wrap follows each write to it.
      class NumberRanges
        BYTE = (-0x80..0x7F)
        HALF = (-0x8000..0x7FFF)
        WHOLE = (Int32::MIN..Int32::MAX)

        # What a step between a list write and a sum can be while the variable is left alone:
        # anything that runs no routine and ends no frame (a timer's tick can run at a wait).
        UNSAFE_BETWEEN = %i[call call_one_of case wait_vblank loop].freeze

        # Operators whose answer is 1 or 0.
        TRUTHS = %i[< <= > >= == != and or].freeze

        # +also_whole+ is variables written outside any statement of +program+, which nothing here
        # can bound.
        def initialize(program, also_whole: [])
          @tables = program.walk.select { |node| node.kind == :table }.to_h { |node| [node.name, node] }
          @lists = lists_declared_once(program)
          @writes = Hash.new { |all, name| all[name] = [] }
          @holding_lists = {}.compare_by_identity
          @declared = (program.kept_widths || []).to_h.transform_values { |width| KeptWidths.lowest(width)..KeptWidths.highest(width) }
          whole = Set.new(also_whole) | Reach::FRAME_VARIABLES | @declared.keys
          program.walk { |node| record_naming(node, whole) }
          @counted_limits = counted_limits(program)
          candidates = @writes.keys.reject { |name| whole.include?(name) }
          @bytes = prove(candidates, BYTE, {})
          @halves = prove(candidates - @bytes, HALF, @bytes.to_h { |name| [name, BYTE] })
          @ranges = @declared.merge(@bytes.to_h { |name| [name, BYTE] }).merge(@halves.to_h { |name| [name, HALF] })
        end

        # The variables proven to stay in +range+ (BYTE or HALF), in the order the program first
        # writes them. A variable in a byte is in two as well.
        def variables_within(range)
          return @bytes if range == BYTE
          return @bytes + @halves if range == HALF

          raise ArgumentError, "variables are proven within a byte or two, not #{range.inspect}"
        end

        # The range variable +name+ stays in through the whole run, or nil where nothing is known.
        # Asked by the tests that hold the proof to the game (test_number_ranges.rb).
        def variable(name) = @ranges[name]

        # The range the value +node+ stays in, or nil where nothing is known. +known+, given a
        # variable's name, may say more of it where the caller asks (a loop's variable is below its
        # count through the loop, ControlFlow#index_below), or nil.
        def range_of_value(node, &known)
          range_of(node, ->(name) { known&.call(name) || @ranges[name] })
        end

        # Whether +range+ (nil for nothing known) lies inside +bounds+.
        def self.inside?(range, bounds) = !range.nil? && range.begin >= bounds.begin && range.end <= bounds.end

        private

        # Each list by its name. A name declared twice, as two scenes can, counts only where both
        # declarations hold the same: otherwise nothing is known of its slots or its length.
        def lists_declared_once(program)
          program.walk.select { |node| node.kind == :list_new }.group_by(&:name).filter_map do |name, made|
            [name, made.first] if made.map { |node| [node.capacity, node.width] }.uniq.one?
          end.to_h
        end

        # +node+'s write into @writes, or every variable it names into +whole+.
        def record_naming(node, whole)
          record_counter_bounds(node)
          case node.kind
          when :var_ref then nil
          when :set, :add, :sub, :clamp then @writes[node.var] << node
          when :copy then @writes[node.dest] << node
          when :repeat then node.index && @writes[node.index] << node
          else whole.merge(names_in(node))
          end
        end

        # Every name a statement holds, however deep in its operands, and the ones
        # Reach::VARIABLES_OF knows it names. A list or a routine's name is caught too, which
        # is harmless: it is never a variable written by a bounded statement, or if it is, that
        # variable is not proven.
        def names_in(node)
          found = [*Reach::VARIABLES_OF[node.kind]&.call(node)]
          node.attrs.each_value { |value| symbols_in(value, found) }
          found
        end

        def symbols_in(value, found)
          case value
          when Symbol then found << value
          when Array then value.each { |item| symbols_in(item, found) }
          when Hash then value.each { |key, item| symbols_in([key, item], found) }
          # What a pool is (on the program) names its variables to say what each holds, not to
          # read or write one.
          when IR::PoolShape, IR::WalkShape then nil
          when Data then value.to_h.each_value { |item| symbols_in(item, found) }
          end
          found
        end

        # For each `add` or `sub` in +node+'s block, the list it is held inside (see the rule).
        def record_counter_bounds(node)
          node.children.each_with_index do |step, at|
            next unless %i[add sub].include?(step.kind)

            list = list_written_at(step.var, node.children.first(at).reverse)
            @holding_lists[step] = list if list
          end
        end

        # The list a `list_set` at +name+ writes, the nearest of +before+ (nearest first) with
        # nothing between that can change +name+; nil for none.
        def list_written_at(name, before)
          before.each do |step|
            return @lists[step.name] if step.kind == :list_set && var_named?(step.index, name) && @lists.key?(step.name)
            return nil unless leaves_alone?(step, name)
          end
          nil
        end

        def leaves_alone?(step, name)
          step.walk.none? do |inner|
            UNSAFE_BETWEEN.include?(inner.kind) || (inner.kind != :var_ref && names_in(inner).include?(name))
          end
        end

        def var_named?(node, name) = node.is_a?(Node) && node.kind == :var_ref && node.name == name

        # The largest set of +candidates+ whose every write lands in +bounds+, assuming each of them is
        # in +bounds+ and each of +known+ ({name => range}) in its range.
        def prove(candidates, bounds, known)
          proven = Set.new(candidates)
          loop do
            ranges = known.merge(@declared).merge(proven.to_h { |name| [name, bounds] })
            vars = ->(name) { ranges[name] }
            dropped = proven.reject { |name| @writes[name].all? { |write| NumberRanges.inside?(write_range(write, bounds, vars), bounds) } }
            return candidates.select { |name| proven.include?(name) } if dropped.empty?

            proven.subtract(dropped)
          end
        end

        # The range +write+ leaves its variable in, given each variable in +bounds+ as +vars+ says.
        def write_range(write, bounds, vars)
          case write.kind
          when :set then range_of(write.value, vars)
          when :copy then vars.call(write.src)
          when :clamp then clamped_range(vars.call(write.var), write.min, write.max, vars)
          when :repeat then turns_range(write, vars)
          when :add, :sub then counter_range(write) || counted_step_range(write, bounds, vars)
          end
        end

        # The one more ending each counted while (LoopForm#counted_while), by itself, with the
        # limit its variable counts below.
        def counted_limits(program)
          form = LoopForm.new(program)
          limits = {}.compare_by_identity
          program.walk do |node|
            counted = form.counted_while(node) if node.kind == :repeat
            limits[counted.step] = counted.limit if counted
          end
          limits
        end

        # A counted while's one more: the loop asks that its variable is below the limit before
        # each turn, and nothing else in the turn writes either, so the sum is at most the limit,
        # and above the variable it was.
        def counted_step_range(write, bounds, vars)
          limit = @counted_limits[write] or return nil
          highest = range_of(limit, vars)&.end or return nil
          (bounds.begin + 1)..highest
        end

        # A loop's turn number runs from nought to its count (a lowering counting in it reaches
        # the count before taking one back, ControlFlow#emit_repeat).
        def turns_range(write, vars)
          count = range_of(write.count, vars)
          0..[count.end, 0].max if count
        end

        def counter_range(write)
          list = @holding_lists[write] or return nil
          amount = KeptWidths.written_number(write.operand) or return nil
          amount = -amount if write.kind == :sub
          ends = [amount, amount + list.capacity - 1]
          ends.min..ends.max
        end

        # --- values ---

        # The range of +node+, with each variable's range from +vars+.
        def range_of(node, vars)
          number = KeptWidths.written_number(node)
          return Int32.wrap(number).then { |n| n..n } if number
          return vars.call(node) if node.is_a?(Symbol)
          return nil unless node.is_a?(Node)

          case node.kind
          when :var_ref then vars.call(node.name)
          when :list_get then slot_range(node.name)
          when :list_len then (0..@lists[node.name].capacity if @lists.key?(node.name))
          when :table_get then table_range(node.name)
          when :binop then binop_range(node, vars)
          when :neg then negated_range(range_of(node.operand, vars))
          when :bit_not then range_of(node.operand, vars)&.then { |range| (-range.end - 1)..(-range.begin - 1) }
          when :absolute then absolute_range(range_of(node.operand, vars))
          when :clamped then clamped_range(range_of(node.operand, vars), node.min, node.max, vars)
          when :shift_right then shifted_down(range_of(node.operand, vars), node.bits)
          when :held, :pressed, :chance, :pixels_overlap then 0..1
          when :data_byte then 0..0xFF
          end
        end

        # A slot keeps its low bits and reads back with their sign (Reference::ListValue).
        def slot_range(name)
          list = @lists[name] or return nil
          bytes = LoweringPlan::SLOT_BYTES.fetch(list.width)
          return nil if bytes == 4

          bits = bytes * 8
          -(1 << (bits - 1))..((1 << (bits - 1)) - 1)
        end

        # Reference#value_of_table_get: one of the table's entries, whatever the index.
        def table_range(name)
          values = @tables[name]&.values
          return nil unless values.is_a?(Array) && !values.empty? && values.all?(Integer)

          wrapped = values.map { |value| Int32.wrap(value) }
          wrapped.min..wrapped.max
        end

        # Within the 32 bits, or nil where Int32's answer could wrap.
        def range_without_wrap(lowest, highest) = (lowest..highest if lowest >= Int32::MIN && highest <= Int32::MAX)

        def binop_range(node, vars)
          return 0..1 if TRUTHS.include?(node.op)

          left, right = range_of(node.lhs, vars), range_of(node.rhs, vars)
          case node.op
          when :+ then range_without_wrap(left.begin + right.begin, left.end + right.end) if left && right
          when :- then range_without_wrap(left.begin - right.end, left.end - right.begin) if left && right
          when :* then product_range(left, right)
          when :& then masked_range(left, right)
          when :|, :^ then bits_range(left, right)
          when :% then remainder_range(left, written_divisor(node.rhs))
          when :/ then quotient_range(left, written_divisor(node.rhs))
          when :<< then shifted_up(left, KeptWidths.written_number(node.rhs))
          when :>> then KeptWidths.written_number(node.rhs)&.then { |count| shifted_down(left, count) }
          end
        end

        # A divisor written in the program as Int32.div and Int32.mod read it, wrapped to 32 bits:
        # 0xFFFF_FFFD divides as -3. A shift count is read as written (Int32.shift_left).
        def written_divisor(node) = KeptWidths.written_number(node)&.then { |number| Int32.wrap(number) }

        def product_range(left, right)
          return nil unless left && right

          corners = [left.begin * right.begin, left.begin * right.end, left.end * right.begin, left.end * right.end]
          range_without_wrap(corners.min, corners.max)
        end

        # A number ANDed with one at or above nought is at or above nought and no bigger than it;
        # two that each fit some bits give one that fits as many.
        def masked_range(left, right)
          highs = [left, right].compact.select { |range| range.begin >= 0 }.map(&:end)
          return 0..highs.min unless highs.empty?

          bits_range(left, right)
        end

        # An OR or XOR (or AND) of two numbers that each fit some bits, with their sign, fits as many;
        # of two at or above nought, it is at or above nought.
        def bits_range(left, right)
          return nil unless left && right

          if left.begin >= 0 && right.begin >= 0
            0..((1 << [left.end, right.end].max.bit_length) - 1)
          else
            bits = [left, right].map { |range| [range.begin.bit_length, range.end.bit_length].max }.max
            -(1 << bits)..((1 << bits) - 1)
          end
        end

        # Int32.mod takes the divisor's sign, so a remainder by a number written in the program is
        # between nought and the divisor; by nought it is the number itself.
        def remainder_range(left, divisor)
          return nil if divisor.nil?
          return left if divisor.zero?
          return (divisor + 1)..0 if divisor.negative?
          return 0..[left.end, divisor - 1].min if left && left.begin >= 0

          0..(divisor - 1)
        end

        # Int32.div truncates toward nought, which keeps the order of numbers divided by the same
        # number at or above one, or at or below minus two (minus one turns the most negative
        # number into itself).
        def quotient_range(left, divisor)
          return nil if divisor.nil? || divisor.zero? || divisor == -1

          left ||= WHOLE
          ends = [Int32.div(left.begin, divisor), Int32.div(left.end, divisor)]
          ends.min..ends.max
        end

        def shifted_up(left, count)
          return nil if count.nil?
          return 0..0 unless Int32.shift_count_in_range?(count)
          return nil unless left

          range_without_wrap(left.begin << count, left.end << count)
        end

        # Int32.shift_right keeps the order of numbers; a count outside 0...32 leaves the sign.
        def shifted_down(left, count)
          left ||= WHOLE
          return (left.begin.negative? ? -1 : 0)..(left.end.negative? ? -1 : 0) unless Int32.shift_count_in_range?(count)

          (left.begin >> count)..(left.end >> count)
        end

        # Int32.neg: the most negative number turned round is itself.
        def negated_range(range)
          (-range.end)..(-range.begin) if range && range.begin > Int32::MIN
        end

        def absolute_range(range)
          return nil unless range && range.begin > Int32::MIN
          return range if range.begin >= 0
          return (-range.end)..(-range.begin) if range.end <= 0

          0..[-range.begin, range.end].max
        end

        # Reference#clamp_value: held at the floor, then at the ceiling. Each of the three only
        # ever moves the answer the way it moves, so the lowest answer is the three lowest held,
        # and the highest the three highest.
        def clamped_range(number, floor, ceiling, vars)
          low, high = range_of(floor, vars), range_of(ceiling, vars)
          return nil unless low && high

          number ||= WHOLE
          [[number.begin, low.begin].max, high.begin].min..[[number.end, low.end].max, high.end].min
        end
      end
    end
  end
end
