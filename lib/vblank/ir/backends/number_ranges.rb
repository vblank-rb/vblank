# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      # What range a number stays in, worked out from the program before anything is lowered.
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
      # A variable's and a list's range are worked out together, as the lowest and highest numbers
      # it can hold through the whole run. Each starts with what it holds as the game starts (a
      # variable nought, a list what each of its declarations fills it with as its slot keeps it, or
      # nought), and is widened by what each of its writes can put there, given the ranges so far
      # of what the write reads, round after round until no range widens. What is left holds every
      # number the run can put there: each write keeps its variable or list inside it as long as
      # what it reads was, so by induction over the run nothing leaves it. A range still growing after WIDENING_ROUNDS rounds (a
      # number added to and masked creeps up a round at a time) has each growing end taken out to
      # the next number of one bit more (#next_bounds), which ends the rounds. So `x - y`
      # with each in 0..2047 is about -2047..2047, not just "two bytes, if both are".
      #
      # A variable's writes widen its range by
      #
      # - `set` to a value: the value's range;
      # - `copy` from a variable: that variable's range;
      # - `clamp` (Reference#exec_clamp holds it at the floor, then the ceiling, which can only move
      #   it toward them);
      # - a `repeat`'s turn number: nought to the count;
      # - `add` or `sub`: the variable's range moved by the operand's; and tighter where it is known,
      #   just after a `list_set` at the variable in the same block with nothing between that can
      #   change it (the write to the list stops the game unless the variable is a slot of it, so
      #   after the sum it is within the list's capacity, moved by that number: a counter filling a
      #   list), or as the one more ending a counted while (Backends::LoopForm#counted_while), whose
      #   loop asks that the variable is below the limit before each turn, so the sum is at most
      #   the limit.
      #
      # A list's writes widen its range by each item written (`list_set`, `list_push`); a slot keeps
      # its low bits, so a number past its slot widens the range to the slot's.
      #
      # WHOLE, with nothing known: a variable any other statement names (a save, a timer, a `case`,
      # an `every`), the frame's own counters, ones the caller names (+also_whole+: written by the
      # lowering itself, as a game loop's own numbers are), and one written by `negate` or `abs`; a
      # list any statement names but to read, write, drop or sort its items (a save, a copy from a
      # table, a fill, a picture or a sound read from it), which reads as its slot's range. One the
      # game declared narrow (IR::KeptWidths) is in its width wherever it is read, since the wrap
      # follows each write to it.
      class NumberRanges
        BYTE = (-0x80..0x7F)
        HALF = (-0x8000..0x7FFF)
        WHOLE = (Int32::MIN..Int32::MAX)

        # What a step between a list write and a sum can be while the variable is left alone:
        # anything that runs no routine and ends no frame (a timer's tick can run at a wait).
        UNSAFE_BETWEEN = %i[call call_one_of case wait_vblank loop].freeze

        # Operators whose answer is 1 or 0.
        TRUTHS = %i[< <= > >= == != and or].freeze

        # Rounds of widening before a range still growing is taken to the next wider bounds.
        WIDENING_ROUNDS = 16

        # The kinds of statement that name a list only to read, write, drop or sort its items, so
        # what it holds is what its writes put there. A list_pack reads its +name+ list's items; the
        # list it writes into is named some other way.
        ITEM_ONLY_KINDS = %i[list_new list_get list_len list_set list_push list_drop list_sort list_pack].freeze

        # The slots a list can be kept in, narrowest first, with the numbers each holds.
        NARROW_SLOTS = { byte: BYTE, half: HALF }.freeze

        # +also_whole+ is variables written outside any statement of +program+, which nothing here
        # can bound.
        def initialize(program, also_whole: [])
          @tables = program.walk.select { |node| node.kind == :table }.to_h { |node| [node.name, node] }
          @lists = lists_declared_once(program)
          @writes = Hash.new { |all, name| all[name] = [] }
          @items_written = Hash.new { |all, name| all[name] = [] }
          @lists_named_elsewhere = Set.new
          @sorted_lists = Set.new
          @holding_lists = {}.compare_by_identity
          @declared = (program.kept_widths || []).to_h.transform_values { |width| KeptWidths.lowest(width)..KeptWidths.highest(width) }
          whole = Set.new(also_whole) | Reach::FRAME_VARIABLES | @declared.keys
          program.walk { |node| record_naming(node, whole) }
          @counted_limits = counted_limits(program)
          variables = @writes.keys.reject { |name| whole.include?(name) }
          @list_ranges = {}
          widen_to_fixed_point(variables, @lists.keys.reject { |name| @lists_named_elsewhere.include?(name) })
          @bytes = variables.select { |name| NumberRanges.inside?(@ranges[name], BYTE) }
          @halves = variables.select { |name| NumberRanges.inside?(@ranges[name], HALF) } - @bytes
          @ranges = @declared.merge(@ranges.reject { |_name, range| range == WHOLE })
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

        # The range the items of list +name+ stay in through the whole run: what its writes put
        # there, or its slot's for a list written some other way.
        def list(name) = @list_ranges[name] || slot_range(name)

        # The lists proven to hold only numbers narrower than their slots, each with the narrowest
        # slot that holds every item exactly (:byte or :half), so a lowering can keep it in that slot:
        # a pool's fields are lists of whole words, though a thing's place on the screen or its speed
        # never needs more than two bytes. Each read is the number the wider slot would have given.
        def list_widths
          @list_widths ||= @list_ranges.filter_map do |name, range|
            width = NARROW_SLOTS.find { |_width, bounds| NumberRanges.inside?(range, bounds) }&.first
            declared = @lists.fetch(name).width
            [name, width] if width && LoweringPlan::SLOT_BYTES.fetch(width) < LoweringPlan::SLOT_BYTES.fetch(declared)
          end.to_h
        end

        # The numbers two bytes hold read without a sign: a place in 256ths of a pixel across a
        # screen, kept with `& 0xFFFF`, reaches past 32767 but never below nought.
        UNSIGNED_HALF = (0..0xFFFF)

        # The lists of whole words proven to hold only 0..65535 that no signed slot holds (a number
        # past 32767), so a lowering can keep each in two bytes read back with no sign. Not one a
        # sort orders or orders by, since a sort compares its numbers with their signs.
        def unsigned_half_lists
          @unsigned_half_lists ||= @list_ranges.filter_map do |name, range|
            next if list_widths.key?(name) || @sorted_lists.include?(name)

            name if @lists.fetch(name).width == :word && NumberRanges.inside?(range, UNSIGNED_HALF)
          end
        end

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
        # Every declaration of each is kept too, in @list_declarations, for what each fills it with.
        def lists_declared_once(program)
          @list_declarations = program.walk.select { |node| node.kind == :list_new }.group_by(&:name)
          @list_declarations.filter_map do |name, made|
            [name, made.first] if made.map { |node| [node.capacity, node.width] }.uniq.one?
          end.to_h
        end

        # +node+'s write into @writes, or every variable it names into +whole+; and its write of a
        # list's item into @items_written, or every list it names some other way into
        # @lists_named_elsewhere.
        def record_naming(node, whole)
          record_counter_bounds(node)
          record_list_naming(node)
          case node.kind
          when :var_ref then nil
          when :set, :add, :sub, :clamp then @writes[node.var] << node
          when :copy then @writes[node.dest] << node
          when :repeat then node.index && @writes[node.index] << node
          else whole.merge(names_in(node))
          end
        end

        def record_list_naming(node)
          node.named_operands.each do |field, held|
            Array(held).flatten.grep(Symbol).each do |name|
              next unless @lists.key?(name)
              next if ITEM_ONLY_KINDS.include?(node.kind) && (field == :name || (node.kind == :list_sort && field == :by))

              @lists_named_elsewhere << name
            end
          end
          @items_written[node.name] << node.value if %i[list_set list_push].include?(node.kind)
          @sorted_lists.merge([node.name, node.by].compact) if node.kind == :list_sort
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

        # The rounds (see the class comment): each of +variables+ in @ranges and each of +lists+ in
        # @list_ranges, widened by their writes until none widens.
        def widen_to_fixed_point(variables, lists)
          @ranges = variables.to_h { |name| [name, 0..0] }
          @list_ranges = lists.to_h { |name| [name, starting_items(name)] }
          vars = ->(name) { @ranges[name] || @declared[name] }
          rounds = 0
          loop do
            variables_before = @ranges.dup
            lists_before = @list_ranges.dup
            grown_variables = variables.select { |name| widen!(@ranges, name, variable_writes_range(name, vars), WHOLE) }
            grown_lists = lists.select { |name| widen!(@list_ranges, name, items_written_range(name, vars), slot_range(name) || WHOLE) }
            return if grown_variables.empty? && grown_lists.empty?

            rounds += 1
            next if rounds <= WIDENING_ROUNDS

            grown_variables.each { |name| @ranges[name] = next_bounds(@ranges[name], variables_before.fetch(name), WHOLE) }
            grown_lists.each do |name|
              @list_ranges[name] = next_bounds(@list_ranges[name], lists_before.fetch(name), slot_range(name) || WHOLE)
            end
          end
        end

        # What list +name+ holds as it is made, by every declaration of it (two scenes can fill it
        # differently): what each fills it with, as its slot keeps it (#kept_in_slot), or nought.
        def starting_items(name)
          starts = @list_declarations.fetch(name).map { |made| made.full_of.nil? ? 0 : kept_in_slot(name, made.full_of) }
          starts.min..starts.max
        end

        # +number+ as a slot of list +name+ keeps it: its low bits, read back with their sign
        # (Reference::ListValue#wrap_to_width).
        def kept_in_slot(name, number)
          number = Int32.wrap(number)
          slot = slot_range(name) or return number
          span = slot.end - slot.begin + 1
          slot.begin + ((number - slot.begin) % span)
        end

        # Widens +ranges+[+name+] to take in +written+ (nil for anything), held to +bounds+; true
        # when it grew.
        def widen!(ranges, name, written, bounds)
          held = ranges[name]
          written = bounds unless written && NumberRanges.inside?(written, bounds)
          widened = [held.begin, written.begin].min..[held.end, written.end].max
          return false if widened == held

          ranges[name] = widened
          true
        end

        # +range+, still growing, each end that moved since +before+ taken out to the next number of
        # one bit more: a top end to the next of -1, 0, 1, 3, 7 ... 2**31 - 1, a bottom end to the
        # next of 0, -1, -2, -4 ... -2**31, held to +widest+, the most the variable or the list's
        # slot can be. Each end can move only 32 times, so the rounds end; and a number masked to
        # 2047 stops at 2047, where taking the whole range to two bytes' bounds would have lost it.
        def next_bounds(range, before, widest)
          low = range.begin
          low = low >= 0 ? 0 : -(1 << (-low - 1).bit_length) if low < before.begin
          high = range.end
          high = high.negative? ? -1 : (1 << high.bit_length) - 1 if high > before.end
          [low, widest.begin].max..[high, widest.end].min
        end

        # What every write of variable +name+ can leave in it, or nil for anything.
        def variable_writes_range(name, vars)
          ranges = @writes[name].map { |write| write_range(write, vars) }
          ranges.include?(nil) ? nil : ranges.reduce { |all, range| [all.begin, range.begin].min..[all.end, range.end].max }
        end

        # What every item written to list +name+ can be, or nil for anything; for a list nothing
        # writes, what it already holds, which widens nothing.
        def items_written_range(name, vars)
          ranges = @items_written[name].map { |value| range_of(value, vars) }
          return @list_ranges[name] if ranges.empty?

          ranges.include?(nil) ? nil : ranges.reduce { |all, range| [all.begin, range.begin].min..[all.end, range.end].max }
        end

        # The range +write+ leaves its variable in, given each variable's range as +vars+ says.
        def write_range(write, vars)
          case write.kind
          when :set then range_of(write.value, vars)
          when :copy then vars.call(write.src)
          when :clamp then clamped_range(vars.call(write.var), write.min, write.max, vars)
          when :repeat then turns_range(write, vars)
          when :add, :sub then counter_range(write) || counted_step_range(write, vars) || stepped_range(write, vars)
          end
        end

        # `add` or `sub`: the variable's range moved by the operand's, where Int32's answer cannot wrap.
        def stepped_range(write, vars)
          held = vars.call(write.var)
          step = range_of(write.operand, vars)
          return nil unless held && step

          write.kind == :add ? range_without_wrap(held.begin + step.begin, held.end + step.end) : range_without_wrap(held.begin - step.end, held.end - step.begin)
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
        def counted_step_range(write, vars)
          limit = @counted_limits[write] or return nil
          highest = range_of(limit, vars)&.end or return nil
          lowest = vars.call(write.var)&.begin or return nil
          [lowest + 1, highest].min..highest
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
          when :list_get then @list_ranges[node.name] || slot_range(node.name)
          when :list_len then (0..@lists[node.name].capacity if @lists.key?(node.name))
          when :table_get then table_range(node.name)
          when :binop then binop_range(node, vars)
          when :neg then negated_range(range_of(node.operand, vars))
          when :bit_not then range_of(node.operand, vars)&.then { |range| (-range.end - 1)..(-range.begin - 1) }
          when :absolute then absolute_range(range_of(node.operand, vars))
          when :clamped then clamped_range(range_of(node.operand, vars), node.min, node.max, vars)
          when :shift_right then shifted_down(range_of(node.operand, vars), node.bits)
          when :held, :pressed, :chance, :pixels_overlap then 0..1
          when :pulled then 0..Buttons::FULL_PULL
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
