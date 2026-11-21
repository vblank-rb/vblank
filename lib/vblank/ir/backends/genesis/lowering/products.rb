# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # Multiplying by a number written in the game, written where the sum is rather than as a call of
          # the runtime's multiply. Mixed into Lowering.
          #
          # The 68000 has no multiply of two long words. The runtime's (rt_mul32) makes one of three of its
          # word multiplies, MULU, each about forty cycles, with the call and the return round them. A
          # number known while the game is built needs none of that: the other side is shifted left and
          # added to itself where the number's bits are set, the way a product is worked out on paper in
          # binary, so ten times is 4x + x doubled. A run of set bits is cheaper taken away from the bit
          # above it: 255 times is 256x - x, one shift and one subtract (the number written in signed
          # digits, ProductSteps.signed_digits). And a number of up to sixteen bits can be multiplied in
          # two MULUs written in place, the low half and the high half of the other side each by the
          # number, which beats a long run of shifts and adds. Whichever of those takes the fewest cycles
          # is written; a number for which even that is longer than the call goes to the runtime.
          #
          # Shifts and adds wrap as the product does, so the low 32 bits are the same whatever the signs
          # (Int32.mul). A number below nought is its size multiplied and the product turned round.
          #
          # These are the products the builder writes all through a game: a place in a table of records
          # (an index times how many numbers a record has), a sprite's picture from the way it faces (the
          # way times how many frames each has), a row of a map (a row times how many cells across).
          #
          # A product by a comparison is the other side while the comparison holds and nought while it
          # does not, since a comparison is 1 or 0: a shown flag times "this scene is up", a digit times
          # "this place is reached". The comparison jumps on its own flags (#emit_product_by_comparison).
          module Products
            # What each step of a product costs, in the 68000's cycles with its operands in data
            # registers (the Motorola manual's instruction timing tables).
            COPY_CYCLES = 4      # move.l d0,d1
            SUM_CYCLES = 8       # add.l d1,d0, sub.l d1,d0, add.l d0,d0
            NEGATE_CYCLES = 6    # neg.l d0
            HALF_SWAP_CYCLES = 8 # swap d0 and clr.w d0: a shift of sixteen places
            WIDEST_SHIFT = 8     # lsl.l #n takes a count of 1 to 8...
            SHIFT_CYCLES = 8     # ...and 8 cycles and 2 a place

            # Two MULUs by a number written in the instruction, each 38 cycles, 2 more for every set bit
            # of the number and 4 to read it; and the five moves, swaps and clears round them and the
            # add that joins the halves.
            WORD_MULTIPLY_CYCLES = (2 * (38 + 4)) + (4 * 4) + SUM_CYCLES + 4
            WIDEST_WORD_MULTIPLIER = 0xFFFF

            # What rt_mul32 takes with the number loaded, the call and the return, before its three MULUs'
            # 2 cycles for each set bit they read: two of them read the low half of the number written in
            # the game, and the third the low half of the game's own number, which is not known here. So
            # this and the written number's bits are the least the call takes.
            CALLED_CYCLES = 202

            # How a product by a number is written: +steps+, each one of
            #   [:keep]              D0 copied into D1, the other side kept to add or take away
            #   [:shift, n]          D0 shifted n places left
            #   [:add] [:subtract]   D1 added to D0, or taken from it
            #   [:negate]            D0 turned round
            #   [:nought]            D0 made nought
            #   [:word_multiply, n]  D0 times n, up to sixteen bits, by two MULUs
            # and the +cycles+ they take.
            ProductSteps = Data.define(:steps, :cycles) do
              # The cheapest way to multiply by +number+, or nil where the call is no longer.
              def self.for(number)
                number = Int32.wrap(number)
                return new(steps: [[:nought]], cycles: COPY_CYCLES) if number.zero?

                size = number.abs
                ways = [binary(size), signed(size)]
                ways << new(steps: [[:word_multiply, size]], cycles: WORD_MULTIPLY_CYCLES + (4 * size.to_s(2).count("1"))) if size <= WIDEST_WORD_MULTIPLIER
                best = ways.min_by(&:cycles)
                best = new(steps: best.steps + [[:negate]], cycles: best.cycles + NEGATE_CYCLES) if number.negative?
                best if best.cycles < CALLED_CYCLES + (4 * (number & 0xFFFF).to_s(2).count("1"))
              end

              # +size+'s set bits, each [its place, +1], from the top.
              def self.binary(size) = from_digits((0...size.bit_length).select { |bit| size[bit] == 1 }.reverse.map { |bit| [bit, 1] })

              def self.signed(size) = from_digits(signed_digits(size))

              # +size+ in signed binary digits, each [its place, +1 or -1], from the top, with no two next
              # to each other (the non-adjacent form), which has the fewest digits that are not nought.
              def self.signed_digits(size)
                digits = []
                place = 0
                while size.positive?
                  if size.odd?
                    digit = 2 - (size % 4)
                    digits << [place, digit]
                    size -= digit
                  end
                  size >>= 1
                  place += 1
                end
                digits.reverse
              end

              # The steps for +digits+, the first +1: D0 is the other side times that digit's place
              # value, shifted down to each next digit's place in turn to have the other side added or
              # taken away there, and shifted to the last place at the end.
              def self.from_digits(digits)
                steps = []
                steps << [:keep] if digits.length > 1
                digits.each_cons(2) do |(place, _), (lower, digit)|
                  steps << [:shift, place - lower] << [digit.positive? ? :add : :subtract]
                end
                steps << [:shift, digits.last.first]
                steps.reject! { |step| step == [:shift, 0] }
                new(steps: steps, cycles: steps.sum { |step| cycles_of(step) })
              end

              def self.cycles_of(step)
                case step.first
                when :keep then COPY_CYCLES
                when :add, :subtract then SUM_CYCLES
                when :shift then shift_cycles(step.last)
                else raise ArgumentError, "no cycles known for #{step.inspect}"
                end
              end

              # A shift of +places+: half swapped for sixteen or more, a doubling for one, and LSL by up
              # to eight at a time.
              def self.shift_cycles(places)
                return 0 if places.zero?
                return HALF_SWAP_CYCLES + shift_cycles(places - 16) if places >= 16
                return SUM_CYCLES if places == 1

                count = [places, WIDEST_SHIFT].min
                SHIFT_CYCLES + (2 * count) + shift_cycles(places - count)
              end
            end

            private

            # Is +number+ one a product by which is written in place with D0 and D1 alone?
            def product_in_place?(number) = !number.nil? && !ProductSteps.for(number).nil?

            # A product by a number written in the program, as ProductSteps says. True when done so.
            def emit_product_by_written_number(node)
              [[node.rhs, node.lhs], [node.lhs, node.rhs]].each do |by, other|
                product = (number = folded(by)) && ProductSteps.for(number)
                next unless product

                value(other)
                product.steps.each { |step| emit_product_step(step) }
                return true
              end
              false
            end

            def emit_product_step(step)
              case step.first
              when :keep then @asm.move(:l, @asm.d(0), @asm.d(1))
              when :add then @asm.add(:l, @asm.d(1), @asm.d(0))
              when :subtract then @asm.sub(:l, @asm.d(1), @asm.d(0))
              when :negate then @asm.neg(:l, @asm.d(0))
              when :nought then @asm.moveq(0, @asm.d(0))
              when :shift then emit_shift_left_of_d0(step.last)
              when :word_multiply then emit_word_multiply_of_d0(step.last)
              else raise LoweringError, "#{step.inspect} is not a step of a product"
              end
            end

            # D0 shifted +places+ left without D1, which holds the other side (ProductSteps.shift_cycles).
            def emit_shift_left_of_d0(places)
              if places >= 16
                @asm.swap(@asm.d(0))
                @asm.clr(:w, @asm.d(0))
                return emit_shift_left_of_d0(places - 16)
              end
              return @asm.add(:l, @asm.d(0), @asm.d(0)) if places == 1

              while places.positive?
                count = [places, WIDEST_SHIFT].min
                @asm.lsl(:l, count, @asm.d(0))
                places -= count
              end
            end

            # D0 times +number+ (up to sixteen bits), the low 32 bits: its high half times the number,
            # moved up sixteen places, added to its low half times the number. What the high half's
            # product carries past sixteen bits goes past the top.
            def emit_word_multiply_of_d0(number)
              @asm.move(:l, @asm.d(0), @asm.d(1))
              @asm.swap(@asm.d(1))
              @asm.mulu(@asm.imm(number), @asm.d(1))
              @asm.swap(@asm.d(1))
              @asm.clr(:w, @asm.d(1))
              @asm.mulu(@asm.imm(number), @asm.d(0))
              @asm.add(:l, @asm.d(1), @asm.d(0))
            end

            # A product of a comparison and another side: the comparison jumps on its flags to D0 made
            # nought when it does not hold, and to the other side worked out when it does. The
            # interpreter works the other side out either way, so it is skipped only where working it
            # out changes nothing (Unchanging), as the Super Nintendo does it. True when done so.
            def emit_product_by_comparison(node)
              [[node.lhs, node.rhs], [node.rhs, node.lhs]].each do |test, other|
                next unless comparison?(test) && unchanging?(other)

                nought = fresh("product_nought")
                done = fresh("product_done")
                jump_unless(test, nought)
                value(other)
                @asm.bra(done)
                @asm.label(nought)
                @asm.moveq(0, @asm.d(0))
                @asm.label(done)
                return true
              end
              false
            end

            # Is +node+ a product #emit_product_by_comparison writes?
            def product_by_comparison?(node)
              [[node.lhs, node.rhs], [node.rhs, node.lhs]].any? { |test, other| comparison?(test) && unchanging?(other) }
            end

            # Does working +operand+ out change nothing (IR::Unchanging)?
            def unchanging?(operand) = operand.is_a?(Symbol) || (operand.is_a?(Node) && Unchanging.value?(operand) { |part| folded(part) })
          end
        end
      end
    end
  end
end
