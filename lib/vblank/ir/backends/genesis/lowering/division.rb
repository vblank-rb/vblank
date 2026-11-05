# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        class Lowering
          # DIVIDING BY A NUMBER WRITTEN IN THE GAME, written where the sum is rather than as a call of
          # the runtime's divide. Mixed into Lowering.
          #
          # The runtime's rt_div32 and rt_mod32 work a quotient out a bit at a time, 32 turns of a loop of
          # seven instructions whatever the numbers are. The 68000 has a divide of its own, DIVU, which
          # takes a 32-bit number and a 16-bit divisor and leaves a 16-bit quotient beside the 16-bit
          # remainder in one instruction, about as long as four turns of that loop: what the console's
          # own games used for a score's digits. Its one catch is the quotient's size. A quotient that will not fit 16 bits
          # sets a flag and leaves the number as it was, so a number the divisor goes into 65536 times or
          # more is divided as on paper in two pieces: its top half first, then the remainder of that in
          # front of its bottom half. Each piece's quotient fits, since what comes down in front of the
          # bottom half is less than the divisor.
          #
          # DIVU knows nothing of signs, so the number's size is divided and the sign put back after: a
          # quotient truncated toward nought takes the sign the two numbers make together, and a remainder
          # takes the divisor's (Int32.mod, Ruby's meaning). The lowest number's size, 2**31, is a number
          # DIVU reads correctly, since it reads the register as unsigned.
          #
          # A power of two is a shift, and a divisor past 16 bits, which DIVU cannot take, still goes to
          # the runtime; so do 1, 0 and -1, which are not worth a case of their own.
          module Division
            # The biggest divisor DIVU takes.
            WIDEST_DIVU_DIVISOR = 0xFFFF

            private

            # `/` by a number written in the program, when it is one worked out here: true when done so.
            def emit_divide_by_number(node)
              divisor = folded(node.rhs)
              return false unless written_divisor?(divisor)

              size = divisor.abs
              value(node.lhs)
              bits = ConstantDivisor.power_of_two_bits(size)
              return emit_quotient_by_power_of_two(bits, size, negated: divisor.negative?) if bits

              emit_size_of_d0
              emit_unsigned_divide_by_word(size)
              # The quotient is below nought when the number and the divisor have different signs.
              done = fresh("quotient_signed")
              @asm.tst(:l, @asm.d(4))
              @asm.branch(divisor.negative? ? :mi : :pl, done)
              @asm.neg(:l, @asm.d(0))
              @asm.label(done)
              true
            end

            # `%` by a number written in the program, when it is one worked out here: true when done so.
            def emit_remainder_by_number(node)
              divisor = folded(node.rhs)
              return false unless written_divisor?(divisor)

              size = divisor.abs
              value(node.lhs)
              return emit_remainder_by_power_of_two(size, negative: divisor.negative?) if ConstantDivisor.power_of_two_bits(size)

              emit_size_of_d0
              emit_unsigned_divide_by_word(size)
              @asm.move(:l, @asm.d(1), @asm.d(0))
              emit_remainder_signed(size, negative: divisor.negative?)
              true
            end

            # A divisor this file divides by: a power of two, or a number DIVU takes, either sign.
            def written_divisor?(divisor)
              return false unless divisor && divisor.abs > 1

              ConstantDivisor.power_of_two_bits(divisor.abs) || divisor.abs <= WIDEST_DIVU_DIVISOR
            end

            # D0 divided by 2**+bits+ (+size+), truncating toward nought, and turned round when +negated+.
            # An arithmetic shift rounds toward minus infinity, so a number below nought has one less
            # than the size added first: -7 / 2 is (-7 + 1) >> 1, which is -3. True.
            def emit_quotient_by_power_of_two(bits, size, negated:)
              positive = fresh("positive")
              @asm.tst(:l, @asm.d(0))
              @asm.branch(:pl, positive)
              emit_add_to_d0(size - 1)
              @asm.label(positive)
              emit_shift_of_d0(:asr, bits)
              @asm.neg(:l, @asm.d(0)) if negated
              true
            end

            # What is left of D0 after a power of two, with the divisor's sign. By a positive one it is
            # the low bits alone (-1 % 16 is 15, and so is -1 & 15). By a negative one, low bits that are
            # not nought are counted down from the divisor: 1 % -16 is -15. True.
            def emit_remainder_by_power_of_two(size, negative:)
              @asm.and(:l, @asm.imm(size - 1), @asm.d(0))
              return true unless negative

              done = fresh("remainder_signed")
              @asm.branch(:eq, done)
              @asm.sub(:l, @asm.imm(Int32.wrap(size)), @asm.d(0))
              @asm.label(done)
              true
            end

            def emit_add_to_d0(number)
              return @asm.addq(:l, number, @asm.d(0)) if number.between?(1, 8)

              @asm.add(:l, @asm.imm(number), @asm.d(0))
            end

            # D0 made its size, the number as it was kept in D4 for its sign.
            def emit_size_of_d0
              @asm.move(:l, @asm.d(0), @asm.d(4))
              @asm.branch_over(:pl, 2)
              @asm.neg(:l, @asm.d(0))
            end

            # D0, read as unsigned, divided by +size+ (2 to 65535) with DIVU: the quotient in D0 and the
            # remainder in D1. One DIVU when the quotient fits 16 bits, which is when the number is below
            # the size times 65536; two otherwise, the top half's remainder brought down in front of the
            # bottom half.
            def emit_unsigned_divide_by_word(size)
              wide = fresh("divide_wide")
              done = fresh("divided")
              by = @asm.imm(size)
              @asm.cmp(:l, @asm.imm(size << 16), @asm.d(0))
              @asm.branch(:cc, wide)
              @asm.divu(by, @asm.d(0)) # D0 = remainder : quotient
              @asm.moveq(0, @asm.d(1))
              @asm.swap(@asm.d(0))
              @asm.move(:w, @asm.d(0), @asm.d(1))
              @asm.clr(:w, @asm.d(0))
              @asm.swap(@asm.d(0))
              @asm.bra(done)
              @asm.label(wide)
              @asm.move(:l, @asm.d(0), @asm.d(1))
              @asm.clr(:w, @asm.d(1))
              @asm.swap(@asm.d(1)) # D1 = the top half
              @asm.divu(by, @asm.d(1)) # D1 = its remainder : its quotient
              @asm.move(:w, @asm.d(1), @asm.d(2))
              @asm.move(:w, @asm.d(0), @asm.d(1)) # D1 = that remainder : the bottom half
              @asm.divu(by, @asm.d(1)) # D1 = remainder : the bottom of the quotient
              @asm.swap(@asm.d(2))
              @asm.move(:w, @asm.d(1), @asm.d(2))
              @asm.move(:l, @asm.d(2), @asm.d(0))
              @asm.clr(:w, @asm.d(1))
              @asm.swap(@asm.d(1))
              @asm.label(done)
            end

            # D0, what is left of the number's size after +size+, given the divisor's sign as Int32.mod
            # does, the number as it was in D4. By a positive divisor a number below nought leaves the
            # size less that, unless it is nought. By a negative one, a number below nought leaves its
            # remainder turned round, and any other the remainder less the size, unless it is nought.
            def emit_remainder_signed(size, negative:)
              done = fresh("remainder_signed")
              if negative
                below = fresh("remainder_below")
                @asm.tst(:l, @asm.d(4))
                @asm.branch(:mi, below)
                @asm.tst(:l, @asm.d(0))
                @asm.branch(:eq, done)
                @asm.sub(:l, @asm.imm(size), @asm.d(0))
                @asm.bra(done)
                @asm.label(below)
                @asm.neg(:l, @asm.d(0))
              else
                @asm.tst(:l, @asm.d(4))
                @asm.branch(:pl, done)
                @asm.tst(:l, @asm.d(0))
                @asm.branch(:eq, done)
                @asm.neg(:l, @asm.d(0))
                @asm.add(:l, @asm.imm(size), @asm.d(0))
              end
              @asm.label(done)
            end
          end
        end
      end
    end
  end
end
