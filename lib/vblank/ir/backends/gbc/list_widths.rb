# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        # THE LISTS THAT ONLY EVER HOLD NARROWER NUMBERS than their slots, so the Color's lowering keeps
        # each in slots of a byte or two (Lowering#list_width). A pool's every field is a list of whole
        # words, and a thing's place on the screen, its speed or its number in a draw order never
        # needs more than two bytes. The Color's processor works a byte at a time: a word slot is four
        # loads, a whole number made of them and four stores, where a byte is one. Keeping one narrower
        # changes nothing the game computes: every number written to it is proven to fit the narrower
        # slot, which keeps it exactly, and a read copies its sign upward as a word slot's would have
        # read it (Reference::ListValue).
        #
        # THE RULE, conservative, the lists' kin of GBC::NarrowVariables: a list is narrowed when every
        # statement naming it is a read of an item or of its length, a write of an item (`list_set`,
        # `list_push`), an item dropped, or a sort (which moves items and writes none), and every
        # number written is proven to lie between two bounds. The bounds are worked out together for
        # every list, starting from what each holds as the game starts (nothing, or what it is
        # filled with) and widening each by what its writes can put in, given what the lists read
        # there can hold, round after round until none widens. A list whose bounds still grow after
        # WIDENING_ROUNDS rounds (a number read, added to and masked, creeps up a round at a time)
        # is taken to hold anything a byte can, then two bytes, then its slot, which ends the rounds.
        # The numbers a write is worked out from: numbers written in the program, a variable kept in
        # a byte or two (declared, or proven by GBC::NarrowVariables), an item of a list, a list's
        # length, a number ANDed with a mask at or above nought, and sums and differences of those.
        #
        # NOT narrowed: a list any other statement names (a save, a copy from a table, a fill, a
        # picture or a sound read from it), or one whose writes reach past what two bytes hold.
        class ListWidths
          # Rounds of widening before a list still growing is taken to the next wider bounds.
          WIDENING_ROUNDS = 16

          # The kinds of statement that name a list only to read, write, drop or sort its items, so
          # what it holds is what its writes put there.
          ITEM_ONLY_KINDS = %i[list_new list_get list_len list_set list_push list_drop list_sort].freeze

          # The slots a list can be narrowed to, narrowest first, with the numbers each holds.
          NARROW_SLOT_BOUNDS = { byte: [-0x80, 0x7F], half: [-0x8000, 0x7FFF] }.freeze

          # +narrow_variables+ maps each variable kept narrower than a word to its width.
          def initialize(program, narrow_variables: {})
            @lists = program.walk.select { |node| node.kind == :list_new }.to_h { |node| [node.name, node] }
            @narrow_variables = narrow_variables
            @writes = Hash.new { |all, name| all[name] = [] }
            named_elsewhere = Set.new
            program.walk { |node| record_naming(node, named_elsewhere) }
            @candidates = @lists.keys.reject { |name| named_elsewhere.include?(name) || @lists[name].width == :byte }
            @widths = bounds_by_list.filter_map do |name, bounds|
              width = NARROW_SLOT_BOUNDS.find { |_width, (low, high)| bounds.nil? || (bounds.first >= low && bounds.last <= high) }&.first
              [name, width] if width && LoweringPlan::SLOT_BYTES.fetch(width) < LoweringPlan::SLOT_BYTES.fetch(@lists[name].width)
            end.to_h
          end

          # Each list narrowed, by name, and the slot it is kept in: :byte or :half.
          attr_reader :widths

          private

          # +node+'s write of a list's item into @writes, or every list it names some other way into
          # +elsewhere+.
          def record_naming(node, elsewhere)
            node.named_operands.each do |field, held|
              Array(held).flatten.grep(Symbol).each do |name|
                next unless @lists.key?(name)
                next if ITEM_ONLY_KINDS.include?(node.kind) && (field == :name || (node.kind == :list_sort && field == :by))

                elsewhere << name
              end
            end
            @writes[node.name] << node.value if %i[list_set list_push].include?(node.kind)
          end

          # Each candidate's bounds, [lowest, highest], or nil for one never written.
          def bounds_by_list
            bounds = @candidates.to_h { |name| [name, starting_bounds(@lists[name])] }
            WIDENING_ROUNDS.times do
              widened = bounds.keys.select { |name| widen_bounds!(bounds, name) }
              return bounds if widened.empty?
            end
            # Each pass takes every list still growing up to the next of a byte's bounds, two bytes'
            # and its slot's, so it ends.
            loop do
              growing = bounds.keys.select { |name| widen_bounds!(bounds, name) }
              return bounds if growing.empty?

              growing.each { |name| bounds[name] = next_bounds(bounds[name], @lists[name]) }
            end
          end

          # The narrowest of a byte's bounds, two bytes' and +list+'s slot's that holds +range+.
          def next_bounds(range, list)
            [*NARROW_SLOT_BOUNDS.values, slot_bounds(list)].find { |low, high| range.first >= low && range.last <= high }
          end

          def starting_bounds(list) = list.full_of.nil? ? nil : [list.full_of, list.full_of]

          # Widen +name+'s bounds in +bounds+, in place, by its writes; true when they grew.
          def widen_bounds!(bounds, name)
            held = bounds[name]
            @writes[name].each do |value|
              written = range_of(value, bounds)
              next if written == :none

              written = clipped(written, @lists[name])
              held = held ? [[held.first, written.first].min, [held.last, written.last].max] : written
            end
            grew = held != bounds[name]
            bounds[name] = held
            grew
          end

          # A list's slot keeps the low bits of what is written, so bounds past it are the slot's own.
          def clipped(range, list)
            low, high = slot_bounds(list)
            range && range.first >= low && range.last <= high ? range : [low, high]
          end

          def slot_bounds(list)
            bits = LoweringPlan::SLOT_BYTES.fetch(list.width) * 8
            [-(1 << (bits - 1)), (1 << (bits - 1)) - 1]
          end

          # The numbers +node+ can be, as [lowest, highest]; nil where nothing is known; :none where it
          # reads a list nothing has been written to yet, so no number reaches it.
          def range_of(node, bounds)
            number = KeptWidths.written_number(node)
            return [number, number] if number
            return nil unless node.is_a?(Node)

            case node.kind
            when :var_ref then variable_range(node.name)
            when :list_get then item_range(node.name, bounds)
            when :list_len then [0, @lists[node.name]&.capacity].then { |range| range.last && range }
            when :binop then binop_range(node, bounds)
            end
          end

          def variable_range(name)
            width = @narrow_variables[name]
            [KeptWidths.lowest(width), KeptWidths.highest(width)] if width
          end

          def item_range(name, bounds)
            return bounds.fetch(name) || :none if bounds.key?(name)

            list = @lists[name]
            slot_bounds(list) if list
          end

          def binop_range(node, bounds)
            left, right = range_of(node.lhs, bounds), range_of(node.rhs, bounds)
            return :none if [left, right].include?(:none)

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
        end
      end
    end
  end
end
