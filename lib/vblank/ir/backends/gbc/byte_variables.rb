# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # THE VARIABLES THAT ONLY EVER HOLD A BYTE, though the game never declared them narrow, so
        # the Color's lowering keeps each in one byte (Lowering::KeptVariables). The Color's
        # processor works a byte at a time, and a four-byte variable read as a list's index is four
        # loads, a bounds check through general code and a whole number made of it; most of a
        # pool's own variables (where its walk is, the slot it took, its links) never hold more
        # than a byte. Keeping one in a byte changes nothing the game computes: every write to it
        # is proven to give a number from -128 to 127, which a byte holds exactly, and a read
        # copies its sign upward to make the whole number again (KeptVariables#load_kept_variable).
        #
        # THE RULE, conservative: a variable is a byte when every statement that names it is a read
        # of it, or a write this analysis can bound, and every write is proven to land in a byte.
        # The proof assumes the variables it names are bytes too, and drops any whose write it
        # cannot prove, over and over until none drops (the largest set that proves itself): a
        # variable starts at nought, and each write keeps it in a byte as long as what it reads
        # was, so by induction over the run every one stays in a byte. A write is proven when it is
        #
        # - `set` to what is worked out to lie in a byte from: numbers written in the program,
        #   byte variables, items of a list of bytes (a slot keeps its low bits and reads them back
        #   with their sign), a list's length (no more than its capacity), a number ANDed with a
        #   mask at or above nought, and sums and differences of those;
        # - `copy` from a byte variable;
        # - `clamp` between two bounds a byte holds;
        # - a `repeat`'s turn number, for a count proven below 128;
        # - `add` or `sub` of a number written in the program, just after a `list_set` at the
        #   variable in the same block with nothing between that can change it: the write to the
        #   list stops the game unless the variable is a slot of it, so after the sum it is within
        #   the list's capacity, moved by that number (a counter filling a list, as a pool's copy
        #   in order is filled).
        #
        # NOT proven, so kept whole: a variable any other statement names (a save, a timer, a
        # `case`, an `every`), one the game declared narrow (it is kept as it said), the frame's
        # own counters, one a sprite is placed from as it stands (#sprite_numbers_read_whole),
        # `negate` and `abs` (-128 turned round is 128), and a sum with no list holding it in.
        class ByteVariables
          LOWEST = -0x80
          HIGHEST = 0x7F

          # What a step between a list write and a sum can be while the variable is left alone:
          # anything that runs no routine and ends no frame (a timer's tick can run at a wait).
          UNSAFE_BETWEEN = %i[call call_one_of case wait_vblank loop].freeze

          # +also_whole+ is variables the lowering writes or reads in four bytes itself, outside
          # any statement of +program+.
          def initialize(program, also_whole: [])
            @lists = program.walk.select { |node| node.kind == :list_new }.to_h { |node| [node.name, node] }
            @writes = Hash.new { |all, name| all[name] = [] }
            @bounds = {}.compare_by_identity
            declared = (program.kept_widths || []).to_h
            @declared_bytes = declared.select { |_name, width| width == :byte }.keys
            whole = Set.new(also_whole) | Reach::FRAME_VARIABLES | declared.keys
            program.walk { |node| record_naming(node, whole) }
            @names = prove(@writes.keys.reject { |name| whole.include?(name) })
          end

          # The variables kept in a byte, in the order the program first writes them.
          attr_reader :names

          private

          # +node+'s write into @writes, or every variable it names into +whole+.
          def record_naming(node, whole)
            record_counter_bounds(node)
            case node.kind
            when :var_ref then nil
            when :object then whole.merge(names_in(node)).merge(sprite_numbers_read_whole(node))
            when :set, :add, :sub, :clamp then @writes[node.var] << node
            when :copy then @writes[node.dest] << node
            when :repeat then node.index && @writes[node.index] << node
            else whole.merge(names_in(node))
            end
          end

          # Every name a statement holds, however deep in its operands, and the ones
          # Reach::VARIABLES_OF knows it names. A list or a routine's name is caught too, which
          # is harmless: it is never a variable written by a bounded statement, or if it is, that
          # variable is kept whole.
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
            when Data then value.to_h.each_value { |item| symbols_in(item, found) }
            end
            found
          end

          # The variables a sprite is placed from as they stand: its pose, its place, its list, whether
          # it is on, and the variable picking a scene's sprites (Picture#showing_parts). A sprite
          # kept as it was is placed by the runtime from a block naming where each of these is kept,
          # read as a whole number there (Picture#posed_sprite_block), so they stay whole and keep
          # that quick way open. A variable only worked into one (`stacked > 31`) is not one.
          def sprite_numbers_read_whole(object)
            active = object.active
            on, scene = active, nil
            if active.is_a?(Node) && active.kind == :binop && active.op == :*
              on = active.lhs
              scene = active.rhs.lhs if active.rhs.is_a?(Node) && active.rhs.kind == :binop && active.rhs.op == :==
            end
            [on, scene, object.pose, object.x, object.y, object.recolor]
              .filter_map { |number| number.name if number.is_a?(Node) && number.kind == :var_ref }
          end

          # For each `add` or `sub` in +node+'s block, the list it is held inside (see the rule).
          def record_counter_bounds(node)
            node.children.each_with_index do |step, at|
              next unless %i[add sub].include?(step.kind)

              list = list_written_at(step.var, node.children.first(at).reverse)
              @bounds[step] = list if list
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

          def prove(candidates)
            proven = Set.new(candidates)
            loop do
              dropped = proven.reject { |name| @writes[name].all? { |write| write_in_byte?(write, proven) } }
              return candidates.select { |name| proven.include?(name) } if dropped.empty?

              proven.subtract(dropped)
            end
          end

          def write_in_byte?(write, proven)
            case write.kind
            when :set then in_byte?(range_of(write.value, proven))
            when :copy then proven.include?(write.src) || @declared_bytes.include?(write.src)
            when :clamp then in_byte?(clamped_range(write, proven))
            when :repeat then in_byte?(turns_range(write, proven))
            when :add, :sub then in_byte?(counter_range(write))
            end
          end

          def in_byte?(range) = !range.nil? && range.first >= LOWEST && range.last <= HIGHEST

          # The numbers +node+ can be, as [lowest, highest], or nil where nothing is known.
          def range_of(node, proven)
            number = KeptWidths.written_number(node)
            return [number, number] if number
            return nil unless node.is_a?(Node)

            case node.kind
            when :var_ref then [LOWEST, HIGHEST] if proven.include?(node.name) || @declared_bytes.include?(node.name)
            when :list_get then item_range(node.name)
            when :list_len then [0, @lists[node.name]&.capacity].then { |range| range.last && range }
            when :binop then binop_range(node, proven)
            end
          end

          # A slot keeps its low bits and reads back with their sign (Reference::ListValue).
          def item_range(name)
            list = @lists[name] or return nil
            bits = LoweringPlan::SLOT_BYTES.fetch(list.width) * 8
            [-(1 << (bits - 1)), (1 << (bits - 1)) - 1]
          end

          def binop_range(node, proven)
            left, right = range_of(node.lhs, proven), range_of(node.rhs, proven)
            case node.op
            when :& then masked_range(left, right)
            when :+ then [left.first + right.first, left.last + right.last] if left && right
            when :- then [left.first - right.last, left.last - right.first] if left && right
            end
          end

          # A number ANDed with one at or above nought is at or above nought and no bigger than it.
          def masked_range(left, right)
            highs = [left, right].compact.select { |range| range.first >= 0 }.map(&:last)
            [0, highs.min] unless highs.empty?
          end

          # Reference#exec_clamp: the number, or one of the bounds, so never outside both.
          def clamped_range(write, proven)
            low, high = range_of(write.min, proven), range_of(write.max, proven)
            [[low.first, high.first].min, [low.last, high.last].max] if low && high
          end

          # A loop's turn number runs from nought to its count (a lowering counting in it reaches
          # the count before taking one back, ControlFlow#emit_repeat).
          def turns_range(write, proven)
            count = range_of(write.count, proven)
            [0, [count.last, 0].max] if count
          end

          def counter_range(write)
            list = @bounds[write] or return nil
            amount = KeptWidths.written_number(write.operand) or return nil
            amount = -amount if write.kind == :sub
            [[amount, amount + list.capacity - 1].min, [amount, amount + list.capacity - 1].max]
          end
        end
      end
    end
  end
end
