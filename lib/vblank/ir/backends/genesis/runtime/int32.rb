# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class Genesis
        module Runtime
          # THE ARITHMETIC OF IR::Int32 that is too long to write where it is used: multiplying,
          # dividing, the remainder, and shifting by a count worked out as the game runs. Adding,
          # subtracting, the bitwise sums, turning a number round and comparing are one instruction
          # each on a processor whose registers are 32 bits wide, and the lowering writes them where
          # they are used (Lowering).
          #
          # THE 68000 MULTIPLIES 16 BITS BY 16 (MULU, into 32) and divides 32 by 16 (DIVU, into a 16-bit
          # quotient and remainder), which is not enough for a 32-bit number. A product of two 32-bit
          # numbers, kept to 32 bits, is the product of the low halves plus the two cross products of
          # a low half and a high half moved up 16 places (the product of the high halves goes past the
          # top). A quotient is found the way it is on paper: one bit of it at a time, 32 times,
          # shifting the number into a remainder and taking the divisor out when it fits.
          #
          # Every routine takes its numbers in D0, D1 and D2 and leaves its answer in D0. They are
          # reached with JSR, and may use every other data register as they like.
          module Int32
            module_function

            def emit(asm)
              emit_mul(asm)
              emit_unsigned_divide(asm)
              emit_div(asm)
              emit_mod(asm)
              emit_shifts(asm)
            end

            # rt_mul32: D0 × D1, the low 32 bits — which are the same whether the two are read as
            # signed or not, so no signs are looked at. With the halves of D0 as a high and a low
            # (aH, aL) and of D1 as bH and bL: aL×bL, plus (aH×bL + aL×bH) up 16 places.
            def emit_mul(asm)
              asm.label("rt_mul32")
              asm.move(:l, asm.d(0), asm.d(2))
              asm.move(:l, asm.d(1), asm.d(3))
              asm.swap(asm.d(2)) # aH
              asm.swap(asm.d(3)) # bH
              asm.mulu(asm.d(1), asm.d(2)) # aH × bL
              asm.mulu(asm.d(0), asm.d(3)) # bH × aL
              asm.add(:l, asm.d(3), asm.d(2))
              asm.swap(asm.d(2))
              asm.clr(:w, asm.d(2)) # the cross products' low half goes up to the high half
              asm.mulu(asm.d(1), asm.d(0)) # aL × bL
              asm.add(:l, asm.d(2), asm.d(0))
              asm.rts
            end

            # rt_unsigned_divide: D0 ÷ D1 as unsigned numbers, D1 not nought: D0 = the quotient, D2 =
            # what is left. D0 is shifted left a place at a time, its top bit going into D2, and
            # D1 is taken out of D2 each time it fits, which makes the bit of the quotient that
            # takes the place D0 just emptied.
            def emit_unsigned_divide(asm)
              asm.label("rt_unsigned_divide")
              asm.moveq(0, asm.d(2))
              asm.moveq(31, asm.d(3))
              asm.label("rt_unsigned_divide_bit")
              asm.add(:l, asm.d(0), asm.d(0)) # the top bit into the carry
              asm.roxl(:l, 1, asm.d(2)) # ...and from there into the bottom of D2
              asm.cmp(:l, asm.d(1), asm.d(2))
              asm.branch(:cs, "rt_unsigned_divide_next") # D2 below D1: the bit stays nought
              asm.sub(:l, asm.d(1), asm.d(2))
              asm.addq(:l, 1, asm.d(0))
              asm.label("rt_unsigned_divide_next")
              asm.dbra(asm.d(3), "rt_unsigned_divide_bit")
              asm.rts
            end

            # rt_div32: D0 ÷ D1 as signed numbers, truncated toward nought (Int32.div): the numbers'
            # sizes divided and the sign put back. Nought as a divisor gives 1, or -1 for a
            # numerator below nought. The lowest number turned round stays itself, which is
            # what its size, 2^31 as an unsigned number, divides to.
            def emit_div(asm)
              asm.label("rt_div32")
              asm.move(:l, asm.d(0), asm.d(4)) # the numerator, for its sign
              asm.tst(:l, asm.d(1))
              asm.branch(:ne, "rt_div32_some")
              asm.moveq(1, asm.d(0))
              asm.tst(:l, asm.d(4))
              asm.branch_over(:pl, 2) # a numerator of nought or more keeps the 1
              asm.moveq(-1, asm.d(0))
              asm.rts
              asm.label("rt_div32_some")
              asm.eor(:l, asm.d(1), asm.d(4)) # the sign of the answer, in D4's top bit
              asm.tst(:l, asm.d(0))
              asm.branch_over(:pl, 2)
              asm.neg(:l, asm.d(0))
              asm.tst(:l, asm.d(1))
              asm.branch_over(:pl, 2)
              asm.neg(:l, asm.d(1))
              asm.jsr(asm.abs_l("rt_unsigned_divide"))
              asm.tst(:l, asm.d(4))
              asm.branch_over(:pl, 2)
              asm.neg(:l, asm.d(0))
              asm.rts
            end

            # rt_mod32: what is left of D0 after D1, with the sign of D1 (Int32.mod: Ruby's meaning,
            # so -1 % 16 is 15). Nought as a divisor leaves the number whole. The sizes are divided
            # and the rest given the numerator's sign, and when that is not nought and not D1's sign,
            # D1 is added to it.
            def emit_mod(asm)
              asm.label("rt_mod32")
              asm.tst(:l, asm.d(1))
              asm.branch(:ne, "rt_mod32_some")
              asm.rts
              asm.label("rt_mod32_some")
              asm.move(:l, asm.d(0), asm.d(4)) # the numerator, for its sign
              asm.move(:l, asm.d(1), asm.d(5)) # the divisor, for its sign and to add
              asm.tst(:l, asm.d(0))
              asm.branch_over(:pl, 2)
              asm.neg(:l, asm.d(0))
              asm.tst(:l, asm.d(1))
              asm.branch_over(:pl, 2)
              asm.neg(:l, asm.d(1))
              asm.jsr(asm.abs_l("rt_unsigned_divide"))
              asm.move(:l, asm.d(2), asm.d(0)) # what is left, a size
              asm.tst(:l, asm.d(4))
              asm.branch_over(:pl, 2)
              asm.neg(:l, asm.d(0)) # with the numerator's sign
              asm.tst(:l, asm.d(0))
              asm.branch(:eq, "rt_mod32_done")
              asm.move(:l, asm.d(0), asm.d(6))
              asm.eor(:l, asm.d(5), asm.d(6)) # the two signs differ when the top bit is set
              asm.branch_over(:pl, 2)
              asm.add(:l, asm.d(5), asm.d(0))
              asm.label("rt_mod32_done")
              asm.rts
            end

            # rt_shl32: D0 shifted left by D1 places; rt_shr32: shifted right, the sign filling in
            # (Int32.shift_left and Int32.shift_right). A count of 32 or more, or below nought (which is
            # a huge number as an unsigned one), empties the number: nought going left, and going
            # right nought or -1 by the sign it had.
            def emit_shifts(asm)
              asm.label("rt_shl32")
              asm.cmp(:l, asm.imm(32), asm.d(1))
              asm.branch(:cs, "rt_shl32_in_range")
              asm.moveq(0, asm.d(0))
              asm.rts
              asm.label("rt_shl32_in_range")
              asm.lsl(:l, asm.d(1), asm.d(0))
              asm.rts

              asm.label("rt_shr32")
              asm.cmp(:l, asm.imm(32), asm.d(1))
              asm.branch(:cs, "rt_shr32_in_range")
              asm.tst(:l, asm.d(0))
              asm.scc(:mi, asm.d(0)) # $FF where it was below nought
              asm.ext(:w, asm.d(0))
              asm.ext(:l, asm.d(0))
              asm.rts
              asm.label("rt_shr32_in_range")
              asm.asr(:l, asm.d(1), asm.d(0))
              asm.rts
            end
          end
        end
      end
    end
  end
end
