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
          # Every routine takes its numbers in a0 and a1 and answers in v0.
          module Int32
            module_function

            def emit(asm)
              emit_divide(asm)
              emit_remainder(asm)
              emit_shifts(asm)
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
