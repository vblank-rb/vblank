# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class PS1
        module Runtime
          # THE ARITHMETIC TOO LONG TO WRITE IN PLACE, as IR::Int32 has it: dividing, the remainder, and
          # shifting by a count the game works out. Adding, subtracting and multiplying are one or two
          # instructions and are written in place by the lowering (ADDU, SUBU, MULT and MFLO).
          #
          # THE R3000'S DIVIDE does most of the work: DIV leaves the quotient, truncated toward nought, in
          # LO and the remainder, with the dividend's sign, in HI. It never stops the processor, and it
          # takes 36 cycles. Two of its answers are not the game's:
          #
          # - Dividing by nought gives -1 for a dividend of nought or more, and 1 for a negative one
          #   (psx-spx, CPU): the opposite of the game's rule, which is 1, or -1 for a negative numerator
          #   (Int32.quotient_by_zero). So nought is tested for first.
          # - The remainder takes the dividend's sign, and the game's `%` the divisor's (Int32.mod: -1 % 16
          #   is 15). So a remainder of the other sign has the divisor added.
          #
          # The lowest number over -1 gives the lowest number back in LO, and nought in HI, which is the
          # wrapped answer the game has too.
          #
          # SHIFTS. SLLV and SRAV use only the low five bits of the count, so a count of 32 would shift by
          # nought. The game's rule is that a count of 32 or more, or below nought, pushes every bit off the
          # end: a shift left gives nought, and a shift right gives the sign, nought or -1 (Int32.shift_left,
          # Int32.shift_right), so the count is tested first. A count compared as a number
          # that cannot be negative is 32 or more for every count out of range, so one test does both.
          #
          # A NUMBER WITH A FRACTION DIVIDED BY ANOTHER (Int32.div_fix). The numerator is first brought up
          # by the fraction's bits, which takes it past 32 bits — 3.0 with sixteen bits of fraction, brought
          # up sixteen more, is 48 bits — and DIV divides only 32 bits by 32. So rt_div_fix divides the two
          # sizes, the numerator's as a 64-bit number in two registers, and puts the sign on afterwards:
          #
          # - When the top half is not below the divisor, the answer has more than 32 bits, and it is held
          #   at the end of the range, as the interpreter holds it. That is also what makes the rest safe:
          #   the answer then fits 32 bits, and what is left over never reaches 32 bits.
          # - When the top half is nought, DIVU does the whole divide in one instruction.
          # - Otherwise the long division of school, done with digits of sixteen bits rather than one bit
          #   at a time, so DIVU works out each digit of the answer (Hacker's Delight, `divlu`, figure 9-3).
          #   The divisor is first moved up until its top bit is set, and the numerator with it, which
          #   changes no quotient. Then each of the answer's two digits is guessed by dividing the top of
          #   what is left by the divisor's top digit; the guess is never too small and at most two too
          #   big, and the divisor's second digit shows which, so it is taken down until it is right. Two
          #   divides and a few multiplies, where a bit at a time was thirty-two times round a loop.
          # - An answer of 2**31 or more does not fit with its sign, and is held too: the highest number
          #   for a positive answer, the lowest for a negative one (where 2**31 is exactly the lowest).
          #
          # Nought as a divisor gives 1, or -1 for a numerator below nought, like every divide. The product
          # of two numbers with a fraction is MULT and the halves of HI and LO joined, short enough to be
          # written in place (Lowering#value_of_mul_fix).
          #
          # Every routine takes its numbers in a0 and a1 (rt_div_fix the fraction's bits, 0 to 32, in a2)
          # and answers in v0.
          module Int32
            module_function

            def emit(asm)
              emit_divide(asm)
              emit_remainder(asm)
              emit_shifts(asm)
              emit_div_fix(asm)
            end

            def emit_div_fix(asm)
              asm.label("rt_div_fix")
              asm.bne(:a1, :zero, "rt_div_fix_some")
              asm.bgez(:a0, "rt_div_fix_return") { asm.li(:v0, 1) }
              asm.jr(:ra) { asm.li(:v0, -1) }
              asm.label("rt_div_fix_some")
              asm.xor(:t7, :a0, :a1) # the answer's sign, in its top bit
              emit_absolute_value(asm, :a0)
              emit_absolute_value(asm, :a1)
              emit_widen_numerator(asm)
              asm.sltu(:t3, :t1, :a1)
              asm.beq(:t3, :zero, "rt_div_fix_too_big")
              asm.bne(:t1, :zero, "rt_div_fix_long")
              asm.divu(:t2, :a1)
              asm.b("rt_div_fix_signed") { asm.mflo(:t2) }
              emit_long_division(asm)
              emit_signed_answer(asm)
            end

            # The size of the number in +register+, in place: the lowest number's is 2**31, which only a
            # number that cannot be negative holds, and that is how it is read from here on.
            def emit_absolute_value(asm, register)
              asm.sra(:t0, register, 31)
              asm.xor(register, register, :t0)
              asm.subu(register, register, :t0)
            end

            # The numerator's size brought up by a2 bits, as 64 bits: the top half in t1, the bottom in t2.
            # SLLV and SRLV count by the low five bits alone, so 32 is put right afterwards; the top half is
            # moved down by one first and then by 31 less the bits, which is 32 less the bits for 0 to 31.
            def emit_widen_numerator(asm)
              asm.sllv(:t2, :a0, :a2)
              asm.srl(:t1, :a0, 1)
              asm.li(:t3, 31)
              asm.subu(:t3, :t3, :a2)
              asm.srlv(:t1, :t1, :t3)
              asm.addiu(:t3, :a2, -32)
              asm.bne(:t3, :zero, "rt_div_fix_split")
              asm.move(:t1, :a0)
              asm.move(:t2, :zero)
              asm.label("rt_div_fix_split")
            end

            # t1:t2 over a1, t1 below a1, into t2 (see A NUMBER WITH A FRACTION above). The divisor moved
            # up is t3, by t4 places; its top digit t5 and its bottom one t6. What is left on top is t1,
            # the numerator's two bottom digits t8 and t2. The answer's top digit is a0, its bottom one a3;
            # a2 is what each guess leaves over.
            def emit_long_division(asm)
              asm.label("rt_div_fix_long")
              asm.move(:t3, :a1)
              asm.move(:t4, :zero)
              [16, 8, 4, 2, 1].each do |places|
                kept = "rt_div_fix_top#{places}"
                asm.srl(:t0, :t3, 32 - places)
                asm.bne(:t0, :zero, kept)
                asm.label("#{kept}_up")
                asm.sll(:t3, :t3, places)
                asm.addiu(:t4, :t4, places)
                asm.label(kept)
              end
              asm.beq(:t4, :zero, "rt_div_fix_moved_up")
              asm.label("rt_div_fix_move_up")
              asm.sllv(:t1, :t1, :t4)
              asm.li(:t0, 32)
              asm.subu(:t0, :t0, :t4)
              asm.srlv(:t0, :t2, :t0)
              asm.or(:t1, :t1, :t0)
              asm.sllv(:t2, :t2, :t4)
              asm.label("rt_div_fix_moved_up")
              asm.srl(:t5, :t3, 16)
              asm.andi(:t6, :t3, 0xFFFF)
              asm.srl(:t8, :t2, 16)
              asm.andi(:t2, :t2, 0xFFFF)
              asm.divu(:t1, :t5)
              asm.mflo(:a0)
              asm.mfhi(:a2)
              emit_digit_correction(asm, "top", :a0, :t8)
              # What is left once the top digit's share is taken away, over the next digit.
              asm.sll(:t9, :t1, 16)
              asm.or(:t9, :t9, :t8)
              asm.multu(:a0, :t3)
              asm.mflo(:t0)
              asm.subu(:t9, :t9, :t0)
              asm.divu(:t9, :t5)
              asm.mflo(:a3)
              asm.mfhi(:a2)
              emit_digit_correction(asm, "bottom", :a3, :t2)
              asm.sll(:t2, :a0, 16)
              asm.or(:t2, :t2, :a3)
            end

            # The guessed digit in +digit+, with a2 left over from dividing by the divisor's top digit
            # (t5), taken down while it is too big: while it is a whole digit's worth or more, or times the
            # divisor's bottom digit (t6) it is past what is left over with the numerator's next digit
            # (+next_digit+) brought down; a2 grows by the top digit each time, and once it is a whole
            # digit's worth or more the guess is right. Changes t0 and v1.
            def emit_digit_correction(asm, which, digit, next_digit)
              again = "rt_div_fix_#{which}_again"
              too_big = "rt_div_fix_#{which}_too_big"
              right = "rt_div_fix_#{which}_right"
              asm.label(again)
              asm.srl(:t0, digit, 16)
              asm.bne(:t0, :zero, too_big)
              asm.multu(digit, :t6)
              asm.mflo(:t0)
              asm.sll(:v1, :a2, 16)
              asm.or(:v1, :v1, next_digit)
              asm.sltu(:t0, :v1, :t0)
              asm.beq(:t0, :zero, right)
              asm.label(too_big)
              asm.addiu(digit, digit, -1)
              asm.addu(:a2, :a2, :t5)
              asm.srl(:t0, :a2, 16)
              asm.beq(:t0, :zero, again)
              asm.label(right)
            end

            # The quotient's size, in t2, given the sign in t7's top bit, or held at the end of the range.
            def emit_signed_answer(asm)
              asm.label("rt_div_fix_signed")
              asm.bltz(:t7, "rt_div_fix_negative")
              asm.bltz(:t2, "rt_div_fix_too_big")
              asm.jr(:ra) { asm.move(:v0, :t2) }
              asm.label("rt_div_fix_negative")
              asm.bltz(:t2, "rt_div_fix_lowest")
              asm.jr(:ra) { asm.subu(:v0, :zero, :t2) }
              asm.label("rt_div_fix_too_big")
              asm.bltz(:t7, "rt_div_fix_lowest")
              asm.lui(:v0, 0x7FFF)
              asm.jr(:ra) { asm.ori(:v0, :v0, 0xFFFF) }
              asm.label("rt_div_fix_lowest")
              asm.jr(:ra) { asm.lui(:v0, 0x8000) }
              asm.label("rt_div_fix_return")
              asm.jr(:ra)
            end

            def emit_divide(asm)
              asm.label("rt_div32")
              asm.bne(:a1, :zero, "rt_div32_divide")
              asm.bgez(:a0, "rt_div32_done") { asm.li(:v0, 1) }
              asm.jr(:ra) { asm.li(:v0, -1) }
              asm.label("rt_div32_divide")
              asm.div(:a0, :a1)
              asm.mflo(:v0)
              asm.label("rt_div32_done")
              asm.jr(:ra)
            end

            def emit_remainder(asm)
              asm.label("rt_mod32")
              asm.bne(:a1, :zero, "rt_mod32_divide")
              asm.jr(:ra) { asm.move(:v0, :a0) }
              asm.label("rt_mod32_divide")
              asm.div(:a0, :a1)
              asm.mfhi(:v0)
              asm.beq(:v0, :zero, "rt_mod32_done")
              asm.xor(:t0, :v0, :a1)
              asm.bgez(:t0, "rt_mod32_done")
              asm.addu(:v0, :v0, :a1)
              asm.label("rt_mod32_done")
              asm.jr(:ra)
            end

            def emit_shifts(asm)
              asm.label("rt_shl32")
              asm.sltiu(:t0, :a1, 32)
              asm.beq(:t0, :zero, "rt_shl32_out")
              asm.jr(:ra) { asm.sllv(:v0, :a0, :a1) }
              asm.label("rt_shl32_out")
              asm.jr(:ra) { asm.move(:v0, :zero) }

              asm.label("rt_shr32")
              asm.sltiu(:t0, :a1, 32)
              asm.beq(:t0, :zero, "rt_shr32_out")
              asm.jr(:ra) { asm.srav(:v0, :a0, :a1) }
              asm.label("rt_shr32_out")
              asm.jr(:ra) { asm.sra(:v0, :a0, 31) }
            end
          end
        end
      end
    end
  end
end
