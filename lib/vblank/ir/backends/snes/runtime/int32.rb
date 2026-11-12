# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE ARITHMETIC OF IR::Int32 that is too long to write where it is used: multiplying,
          # dividing, the remainder, shifting by a count worked out as the game runs, and the two
          # sums on numbers with a fraction. Adding, subtracting, the bitwise sums, turning a number
          # round and comparing are a handful of instructions each, and the lowering writes them
          # where they are used (Lowering).
          #
          # A 32-bit number is two 16-bit halves, the low one first, as the console keeps a number
          # anywhere in memory. With A 16 bits wide, a sum of two numbers is a sum of the low halves
          # and then of the high halves with the carry from the first — the 65816 adds with the
          # carry it was left with (ADC), so the carry flag is cleared before the first.
          #
          # The console has a multiplier and a divider of its own, but they take 8 bits by 8 and 16
          # by 8, so a 32-bit product is many of them added up. The sums on numbers with a fraction
          # are worked a byte at a time with them, the way it is done on paper in base 256. The
          # others use them where the numbers fit, and otherwise go one bit of the multiplier (or of
          # the quotient) at a time, at most 32 times, shifting and adding.
          #
          # Nothing that runs in the screen's interrupt uses the multiplier or the divider, so a
          # routine here can write one and read its answer cycles later without it being changed.
          # The picture unit has a multiplier too (M7A and M7B, 16 bits by 8 with the answer at
          # once), but it is the turning layer's: a game that turns a layer needs those registers
          # left alone while the screen is drawn.
          #
          # Every routine takes its numbers in R0, R1 and R2 (Memory.register) and leaves its answer
          # in R0. They are reached with JSL and return with RTL, with A, X and Y 16 bits wide on
          # the way in and the way out.
          module Int32
            R0 = Memory.register(0)
            R1 = Memory.register(1)
            R2 = Memory.register(2)

            # Where the routines keep what they are working on, on the direct page: a product or a
            # numerator of up to 64 bits, what is added to it, the remainder, and the signs; and for
            # a game whose numbers have fractions, +fraction+, FRACTION_BYTES that rt_mul_fix keeps
            # R0's bytes in, a word each, and rt_div_fix its numerator in, a byte at a time (nil for
            # any other game, which carries neither routine).
            Scratch = Data.define(:wide, :addend, :rest, :signs, :fraction)

            # rt_div_fix's numerator: up to twelve bytes once widened (a number of 32 bits, moved up
            # by the fraction's bits and by as many again as bring the divisor's top bit to the top),
            # and two more that a step reads past the top of it, which stay nought.
            FRACTION_BYTES = 14

            module_function

            # +fractions+ is whether the game multiplies or divides numbers with a fraction.
            def scratch(memory, fractions: true)
              Scratch.new(wide: memory.scratch(8), addend: memory.scratch(8), rest: memory.scratch(4),
                          signs: memory.scratch(2), fraction: (memory.scratch(FRACTION_BYTES) if fractions))
            end

            # +divides+ is whether the game has a division a routine works out. One without has no use
            # for those routines, nor one without fractions for rt_mul_fix and rt_div_fix, and they
            # are not small.
            def emit(asm, scratch, divides: true)
              emit_mul(asm, scratch)
              if divides
                emit_unsigned_divide(asm, scratch)
                emit_div(asm, scratch)
                emit_mod(asm, scratch)
              end
              emit_shifts(asm)
              if scratch.fraction
                emit_mul_fix(asm, scratch)
                emit_div_fix(asm, scratch)
              end
              emit_helpers(asm)
              emit_make_positive(asm, scratch)
            end

            # rt_mul32: R0 × R1, the low 32 bits — which are the same whether the two are read as
            # signed or not, so no signs are looked at. R0 is shifted left a place for every bit of R1,
            # and added to the product where that bit is one.
            #
            # THE CONSOLE MULTIPLIES TWO BYTES BY ITSELF, in eight cycles, against a dozen
            # instructions a bit here. Most sums a game does are a small number by a byte, a row
            # by its width, so when one number is a byte and the other fits 16 bits it is two of
            # those: the byte by each half of the other, the second a byte up.
            def emit_mul(asm, s)
              p = s.wide
              h = Console::SNESHardware
              asm.label("rt_mul32")
              asm.stz(asm.direct(p))
              asm.stz(asm.direct(p + 2))
              asm.lda(asm.direct(R0 + 2))
              asm.ora(asm.direct(R1 + 2))
              asm.bne("rt_mul32_bit")
              asm.lda(asm.direct(R1))
              asm.cmp(0x100)
              asm.bcc("rt_mul32_bytes")
              asm.lda(asm.direct(R0))
              asm.cmp(0x100)
              asm.bcs("rt_mul32_bit")
              asm.ldx(asm.direct(R1)) # the byte in R1, the other in R0
              asm.sta(asm.direct(R1))
              asm.stx(asm.direct(R0))
              asm.label("rt_mul32_bytes")
              asm.sep(0x20)
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs(h::WRMPYA))
              asm.lda(asm.direct(R0))
              asm.sta(asm.abs(h::WRMPYB))
              4.times { asm.nop }
              asm.rep(0x20)
              asm.lda(asm.abs(h::RDMPYL))
              asm.sta(asm.direct(p))
              asm.sep(0x20)
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs(h::WRMPYA))
              asm.lda(asm.direct(R0 + 1))
              asm.sta(asm.abs(h::WRMPYB))
              4.times { asm.nop }
              asm.rep(0x20)
              asm.lda(asm.abs(h::RDMPYL))
              asm.clc
              asm.adc(asm.direct(p + 1))
              asm.sta(asm.direct(p + 1))
              asm.bra("rt_mul32_done")
              asm.label("rt_mul32_bit")
              asm.lda(asm.direct(R1))
              asm.ora(asm.direct(R1 + 2))
              asm.beq("rt_mul32_done")
              asm.lsr(asm.direct(R1 + 2))
              asm.ror(asm.direct(R1))
              asm.bcc("rt_mul32_shift")
              asm.clc
              asm.lda(asm.direct(p))
              asm.adc(asm.direct(R0))
              asm.sta(asm.direct(p))
              asm.lda(asm.direct(p + 2))
              asm.adc(asm.direct(R0 + 2))
              asm.sta(asm.direct(p + 2))
              asm.label("rt_mul32_shift")
              asm.asl(asm.direct(R0))
              asm.rol(asm.direct(R0 + 2))
              asm.bra("rt_mul32_bit")
              asm.label("rt_mul32_done")
              asm.lda(asm.direct(p))
              asm.sta(asm.direct(R0))
              asm.lda(asm.direct(p + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.rtl
            end

            # rt_udiv32 (reached with JSR from the routines below, in the same bank): R0 ÷ R1 as
            # numbers that cannot be negative, the quotient left in R0 and the remainder in the
            # scratch's rest. Long division, a bit at a time: the numerator is shifted into the
            # remainder from the top, and wherever the divisor goes into it, it is taken away and a
            # one goes into the quotient, which fills R0 from the bottom as the numerator leaves it.
            #
            # A STEP THAT CAN ONLY GIVE NOUGHT NEED NOT BE WALKED. While what has come over into the
            # remainder is less than the divisor, the divisor does not go in, so a step does nothing
            # but move one bit. When the numerator's top half is less than the divisor, the first
            # sixteen steps are all like that and the half moves across at once; and when that half
            # was nothing and the divisor is more than a byte, so are the next eight. A divisor of a
            # byte never gets here (#emit_divide_by_byte), so the second holds whenever it is asked.
            def emit_unsigned_divide(asm, s)
              rest = s.rest
              asm.label("rt_udiv32")
              asm.lda(asm.direct(R1 + 2))
              asm.bne("rt_udiv32_words")
              asm.lda(asm.direct(R1))
              asm.cmp(0x100)
              asm.bcs("rt_udiv32_words")
              asm.brl("rt_udiv32_byte")
              asm.label("rt_udiv32_words")
              asm.stz(asm.direct(rest))
              asm.stz(asm.direct(rest + 2))
              asm.ldx(32)
              asm.lda(asm.direct(R0 + 2))
              asm.ldy(asm.direct(R1 + 2))
              asm.bne("rt_udiv32_top_half_over")
              asm.cmp(asm.direct(R1))
              asm.bcs("rt_udiv32_bit")
              asm.label("rt_udiv32_top_half_over")
              asm.sta(asm.direct(rest))
              asm.tay
              asm.lda(asm.direct(R0))
              asm.sta(asm.direct(R0 + 2))
              asm.stz(asm.direct(R0))
              asm.ldx(16)
              asm.tya
              asm.bne("rt_udiv32_bit")
              asm.lda(asm.direct(R0 + 2)) # the numerator, under 16 bits: its top byte over too
              asm.xba
              asm.tay
              asm.and_a(0x00FF)
              asm.sta(asm.direct(rest))
              asm.tya
              asm.and_a(0xFF00)
              asm.sta(asm.direct(R0 + 2))
              asm.ldx(8)
              asm.label("rt_udiv32_bit")
              asm.asl(asm.direct(R0))
              asm.rol(asm.direct(R0 + 2))
              asm.rol(asm.direct(rest))
              asm.rol(asm.direct(rest + 2))
              asm.sec
              asm.lda(asm.direct(rest))
              asm.sbc(asm.direct(R1))
              asm.tay
              asm.lda(asm.direct(rest + 2))
              asm.sbc(asm.direct(R1 + 2))
              asm.bcc("rt_udiv32_no")
              asm.sta(asm.direct(rest + 2))
              asm.sty(asm.direct(rest))
              asm.inc(asm.direct(R0))
              asm.label("rt_udiv32_no")
              asm.dex
              asm.bne("rt_udiv32_bit")
              asm.rts
              emit_divide_by_byte(asm, s)
            end

            # THE CONSOLE DIVIDES 16 BITS BY A BYTE BY ITSELF, in sixteen cycles, against dozens of
            # instructions for a single bit here. So a divisor of a byte goes to it, and a numerator
            # too long for it goes as long division on paper does, with the remainder of each piece
            # coming down in front of the next: the top half first, then a byte, then a byte. Each
            # byte's quotient fits a byte, since what comes down in front of it is less than the
            # divisor. The divisor is not nought: rt_div32 and rt_mod32 have seen to that.
            def emit_divide_by_byte(asm, s)
              h = Console::SNESHardware
              rest = s.rest
              asm.label("rt_udiv32_byte")
              asm.stz(asm.direct(rest + 2))
              asm.lda(asm.direct(R0 + 2))
              asm.beq("rt_udiv32_byte_low_half")
              emit_console_divide(asm)
              asm.lda(asm.abs(h::RDDIVL))
              asm.sta(asm.direct(R0 + 2))
              [1, 0].each do |byte|
                asm.lda(asm.abs(h::RDMPYL)) # the divider leaves its remainder here
                asm.xba
                asm.sep(0x20)
                asm.lda(asm.direct(R0 + byte))
                asm.rep(0x20)
                emit_console_divide(asm)
                asm.sep(0x20)
                asm.lda(asm.abs(h::RDDIVL))
                asm.sta(asm.direct(R0 + byte))
                asm.rep(0x20)
              end
              asm.bra("rt_udiv32_byte_done")
              asm.label("rt_udiv32_byte_low_half")
              asm.lda(asm.direct(R0))
              emit_console_divide(asm)
              asm.lda(asm.abs(h::RDDIVL))
              asm.sta(asm.direct(R0))
              asm.label("rt_udiv32_byte_done")
              asm.lda(asm.abs(h::RDMPYL))
              asm.sta(asm.direct(rest))
              asm.rts
            end

            # A ÷ R1's low byte on the console's divider, and the wait for its answer: sixteen cycles
            # from the write, and the REP and these NOPs are all there is to do in them.
            def emit_console_divide(asm)
              h = Console::SNESHardware
              asm.sta(asm.abs(h::WRDIVL)) # both bytes, this and WRDIVH
              asm.sep(0x20)
              asm.lda(asm.direct(R1))
              asm.sta(asm.abs(h::WRDIVB))
              asm.rep(0x20)
              7.times { asm.nop }
            end

            # rt_div32: R0 ÷ R1, rounded towards nought (Int32.div). By nought it is 1, or -1 for a
            # negative numerator. The two are made positive and divided, and the quotient turned
            # round when one of them was negative. The lowest number divided by -1 comes out as itself,
            # as Int32 has it: its size, 2^31, is the lowest number again.
            def emit_div(asm, s)
              asm.label("rt_div32")
              asm.lda(asm.direct(R1))
              asm.ora(asm.direct(R1 + 2))
              asm.bne("rt_div32_divide")
              asm.jmp(asm.abs("rt_one_signed_like_r0"))
              asm.label("rt_div32_divide")
              asm.jsr(asm.abs("rt_make_positive"))
              asm.jsr(asm.abs("rt_udiv32"))
              asm.lda(asm.direct(s.signs))
              asm.eor(asm.direct(s.signs + 1)) # the two signs' top bits, compared in one byte... see below
              asm.and_a(0x0080)
              asm.beq("rt_div32_done")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.label("rt_div32_done")
              asm.rtl
            end

            # rt_mod32: R0 modulo R1, with Ruby's meaning (Int32.mod): the answer takes the sign of
            # the divisor. By nought it is R0 itself. The remainder of the two made positive, given
            # the numerator's sign, and then the divisor added to it when it is not nought and its
            # sign is not the divisor's.
            def emit_mod(asm, s)
              rest = s.rest
              asm.label("rt_mod32")
              asm.lda(asm.direct(R1))
              asm.ora(asm.direct(R1 + 2))
              asm.bne("rt_mod32_divide")
              asm.rtl
              asm.label("rt_mod32_divide")
              # The divisor as it was, for adding at the end.
              asm.lda(asm.direct(R1))
              asm.sta(asm.direct(R2))
              asm.lda(asm.direct(R1 + 2))
              asm.sta(asm.direct(R2 + 2))
              asm.jsr(asm.abs("rt_make_positive"))
              asm.jsr(asm.abs("rt_udiv32"))
              asm.lda(asm.direct(rest))
              asm.sta(asm.direct(R0))
              asm.lda(asm.direct(rest + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.lda(asm.direct(s.signs))
              asm.and_a(0x0080) # the numerator's sign
              asm.beq("rt_mod32_signed")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.label("rt_mod32_signed")
              asm.lda(asm.direct(R0))
              asm.ora(asm.direct(R0 + 2))
              asm.beq("rt_mod32_done")
              asm.lda(asm.direct(R0 + 2))
              asm.eor(asm.direct(R2 + 2))
              asm.bpl("rt_mod32_done")
              asm.clc
              asm.lda(asm.direct(R0))
              asm.adc(asm.direct(R2))
              asm.sta(asm.direct(R0))
              asm.lda(asm.direct(R0 + 2))
              asm.adc(asm.direct(R2 + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.label("rt_mod32_done")
              asm.rtl
            end

            # rt_shl32 and rt_shr32: R0 shifted by R1 places. A count of 32 or more, or below
            # nought, empties the number (Int32.shift_left), or for a shift right leaves only its
            # sign (Int32.shift_right, which rounds down as the arithmetic shift does). A count of
            # 16 or more moves a half at once first.
            def emit_shifts(asm)
              { "rt_shl32" => :left, "rt_shr32" => :right }.each do |name, way|
                asm.label(name)
                asm.lda(asm.direct(R1 + 2))
                asm.bne("#{name}_out")
                asm.lda(asm.direct(R1))
                asm.cmp(32)
                asm.bcs("#{name}_out")
                asm.cmp(16)
                asm.bcc("#{name}_bits")
                asm.sbc(16) # the carry is set: exactly 16 off
                asm.sta(asm.direct(R1))
                if way == :left
                  asm.lda(asm.direct(R0))
                  asm.sta(asm.direct(R0 + 2))
                  asm.stz(asm.direct(R0))
                else
                  asm.lda(asm.direct(R0 + 2))
                  asm.sta(asm.direct(R0))
                  asm.jsr(asm.abs("rt_sign_half"))
                  asm.sta(asm.direct(R0 + 2))
                end
                asm.label("#{name}_bits")
                asm.ldx(asm.direct(R1))
                asm.beq("#{name}_done")
                asm.label("#{name}_bit")
                if way == :left
                  asm.asl(asm.direct(R0))
                  asm.rol(asm.direct(R0 + 2))
                else
                  asm.lda(asm.direct(R0 + 2))
                  asm.cmp(0x8000) # the sign into the carry, to come in at the top
                  asm.ror(asm.direct(R0 + 2))
                  asm.ror(asm.direct(R0))
                end
                asm.dex
                asm.bne("#{name}_bit")
                asm.label("#{name}_done")
                asm.rtl
                asm.label("#{name}_out")
                if way == :left
                  asm.stz(asm.direct(R0))
                else
                  asm.jsr(asm.abs("rt_sign_half"))
                  asm.sta(asm.direct(R0))
                end
                asm.sta(asm.direct(R0 + 2)) if way == :right
                asm.stz(asm.direct(R0 + 2)) if way == :left
                asm.rtl
              end
            end

            # rt_mul_fix: R0 × R1 shifted right R2 places (0 to 32), rounding down, the low 32 bits
            # of that (Int32.mul_fix). The whole product is 64 bits: the two made positive and
            # multiplied a byte by a byte on the console's multiplier, turned round when one of them
            # was negative, then shifted.
            #
            # SIXTEEN PRODUCTS OF A BYTE BY A BYTE make the whole product, each added in where its
            # two bytes' places put it: byte i of R0 by byte j of R1 lands i + j bytes up. Added one
            # 16-bit word at a time, a product lands on an even byte or an odd one; so the ones on
            # even bytes are added into one sum (the scratch's wide number) and the ones on odd
            # bytes into another (its addend, a byte down), each a word at a time with no word
            # overlapping the next, and the two are added together once, a byte apart. A carry out
            # of a word is rare, and goes up a word at a time only as far as it must: neither sum
            # is more than the whole product, so it never goes past the top.
            #
            # A BYTE OF NOUGHT IS SKIPPED. A number with a fraction is mostly small, so its top bytes
            # are nought: R1's are skipped a row at a time, and R0's, spread first into a word each
            # (the fraction scratch), one product at a time.
            #
            # The multiplier writes its answer eight cycles after its second byte, and its second
            # byte is written as a word, the byte after it going harmlessly to WRDIVL; the eight
            # cycles go on reading the sum the product is added to.
            #
            # Brought down R2 places, the answer is the four bytes R2 / 8 up, moved down the rest of
            # R2 one bit at a time, with the bits from the byte above them coming in at the top.
            def emit_mul_fix(asm, s)
              h = Console::SNESHardware
              even = s.wide
              odd = s.addend
              spread = s.fraction
              asm.label("rt_mul_fix")
              asm.jsr(asm.abs("rt_make_positive"))
              4.times do |i|
                asm.lda(asm.direct(R0 + i))
                asm.and_a(0x00FF)
                asm.sta(asm.direct(spread + (2 * i)))
              end
              4.times do |i|
                asm.stz(asm.direct(even + (2 * i)))
                asm.stz(asm.direct(odd + (2 * i)))
              end
              4.times do |j|
                asm.label("rt_mul_fix_row_#{j}")
                asm.sep(0x20)
                asm.lda(asm.direct(R1 + j))
                asm.branch_long(:beq, "rt_mul_fix_row_#{j + 1}")
                asm.sta(asm.abs(h::WRMPYA))
                asm.rep(0x20)
                4.times do |i|
                  k = i + j
                  sum, at = k.even? ? [even, k] : [odd, k - 1]
                  skip = "rt_mul_fix_skip_#{j}_#{i}"
                  asm.lda(asm.direct(spread + (2 * i)))
                  asm.beq(skip)
                  asm.sta(asm.abs(h::WRMPYB))
                  asm.clc
                  asm.lda(asm.direct(sum + at))
                  asm.nop
                  asm.adc(asm.abs(h::RDMPYL))
                  asm.sta(asm.direct(sum + at))
                  asm.bcc(skip)
                  (at + 2).step(6, 2) do |up|
                    asm.inc(asm.direct(sum + up))
                    asm.bne(skip) if up < 6
                  end
                  asm.label(skip)
                end
              end
              asm.label("rt_mul_fix_row_4")
              asm.rep(0x20)
              asm.clc
              [1, 3, 5].each do |at|
                asm.lda(asm.direct(even + at))
                asm.adc(asm.direct(odd + at - 1))
                asm.sta(asm.direct(even + at))
              end
              asm.sep(0x20)
              asm.lda(asm.direct(even + 7))
              asm.adc(asm.direct(odd + 6))
              asm.sta(asm.direct(even + 7))
              asm.rep(0x20)
              asm.lda(asm.direct(s.signs))
              asm.eor(asm.direct(s.signs + 1))
              asm.and_a(0x0080)
              asm.beq("rt_mul_fix_down")
              emit_negate_wide(asm, even)
              asm.label("rt_mul_fix_down")
              asm.lda(asm.direct(R2))
              asm.lsr
              asm.lsr
              asm.lsr
              asm.tax
              asm.lda(asm.direct_x(even))
              asm.sta(asm.direct(R0))
              asm.lda(asm.direct_x(even + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.lda(asm.direct(R2))
              asm.and_a(7)
              asm.beq("rt_mul_fix_done")
              asm.tay
              # The byte above: what comes in at the top. The byte above that, read with it, moves
              # at most seven places, so none of it reaches the answer.
              asm.lda(asm.direct_x(even + 4))
              asm.label("rt_mul_fix_place")
              asm.lsr
              asm.ror(asm.direct(R0 + 2))
              asm.ror(asm.direct(R0))
              asm.dey
              asm.bne("rt_mul_fix_place")
              asm.label("rt_mul_fix_done")
              asm.rtl
            end

            # rt_div_fix: R0 shifted left R2 places (0 to 32), divided by R1, rounded towards nought,
            # and held to the range of a 32-bit number (Int32.div_fix). By nought it is 1, or -1 for
            # a negative numerator. The two are made positive and divided, and the quotient turned
            # round when one of them was negative.
            #
            # LONG DIVISION IN BASE 256, a byte of the quotient at a time, the way it is done on paper
            # (Knuth's Algorithm D). The divisor is moved up until its top bit is set, and the
            # numerator, widened by R2, is moved up as far again (the fraction scratch, a byte at a
            # time), which leaves the quotient as it was. Then, from the top: what has come down so
            # far, five bytes, is divided by the divisor's four. A guess at that byte of the quotient
            # is the top two bytes over the divisor's top byte, on the console's divider; with the
            # divisor's top bit set, the guess is never under and at most two over. The guess times
            # the divisor (four products, a byte of nought skipped as rt_mul_fix skips one, from the
            # scratch's addend: the even products, then the odd) is taken away, and while that went
            # below nought the divisor is added back and the guess made one less.
            #
            # A STEP THAT CAN ONLY GIVE NOUGHT IS SKIPPED. The steps start one byte above the
            # numerator's top four, since nothing above them can hold the divisor, and a step is a
            # compare when its top two bytes are less than the divisor's top byte, which then does
            # not go in. A quotient past 31 bits is held at the end of the range, so a byte of it
            # past the fourth stops the division.
            #
            # R1 and R2 are left changed, as rt_mul_fix leaves them: no caller reads them after.
            def emit_div_fix(asm, s)
              u = s.fraction
              t = s.wide
              even = s.addend
              odd = s.addend + 4
              top = s.rest # the divisor's top byte, as a word
              guess = s.rest + 2
              asm.label("rt_div_fix")
              asm.lda(asm.direct(R1))
              asm.ora(asm.direct(R1 + 2))
              asm.bne("rt_div_fix_divide")
              asm.jmp(asm.abs("rt_one_signed_like_r0"))
              asm.label("rt_div_fix_divide")
              asm.jsr(asm.abs("rt_make_positive"))
              asm.lda(asm.direct(R0))
              asm.ora(asm.direct(R0 + 2))
              asm.bne("rt_div_fix_some")
              asm.rtl
              asm.label("rt_div_fix_some")
              emit_div_fix_normalize_divisor(asm)
              asm.lda(asm.direct(R1 + 3))
              asm.and_a(0x00FF)
              asm.sta(asm.direct(top))
              # The guess's word holds the numerator's fifth byte until the steps begin.
              emit_div_fix_spread_numerator(asm, u, guess)
              2.times do |i|
                asm.stz(asm.direct(even + (2 * i)))
                asm.stz(asm.direct(odd + (2 * i)))
              end
              asm.stz(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              # The first step: the one whose five bytes hold the numerator's top byte, which the
              # spread left X four below. Above it there is less than the divisor.
              asm.inx
              asm.label("rt_div_fix_digit")
              asm.lda(asm.direct_x(u + 3))
              asm.cmp(asm.direct(top))
              asm.branch_long(:bcc, "rt_div_fix_next")
              emit_div_fix_guess(asm, u, top, guess)
              emit_div_fix_product(asm, even, odd, guess, t)
              asm.sec
              3.times do |i|
                asm.lda(asm.direct_x(u + (2 * i)))
                asm.sbc(asm.direct(t + (2 * i)))
                asm.sta(asm.direct_x(u + (2 * i)))
              end
              asm.bcs("rt_div_fix_taken")
              asm.label("rt_div_fix_over")
              asm.dec(asm.direct(guess))
              asm.clc
              asm.lda(asm.direct_x(u))
              asm.adc(asm.direct(R1))
              asm.sta(asm.direct_x(u))
              asm.lda(asm.direct_x(u + 2))
              asm.adc(asm.direct(R1 + 2))
              asm.sta(asm.direct_x(u + 2))
              asm.lda(asm.direct_x(u + 4))
              asm.adc(0)
              asm.sta(asm.direct_x(u + 4))
              asm.bcc("rt_div_fix_over")
              asm.label("rt_div_fix_taken")
              asm.lda(asm.direct(guess))
              asm.beq("rt_div_fix_next")
              asm.cpx(4)
              asm.bcs("rt_div_fix_too_big")
              asm.sep(0x20)
              asm.sta(asm.direct_x(R0))
              asm.rep(0x20)
              asm.label("rt_div_fix_next")
              asm.dex
              asm.branch_long(:bpl, "rt_div_fix_digit")
              emit_div_fix_sign_and_clamp(asm, s)
            end

            # The divisor in R1 moved up until its top bit is set, R2 counting the places: a half at
            # once, then a byte, then a bit at a time.
            def emit_div_fix_normalize_divisor(asm)
              asm.lda(asm.direct(R1 + 2))
              asm.bne("rt_div_fix_half_up")
              asm.lda(asm.direct(R1))
              asm.sta(asm.direct(R1 + 2))
              asm.stz(asm.direct(R1))
              asm.lda(asm.direct(R2))
              asm.clc
              asm.adc(16)
              asm.sta(asm.direct(R2))
              asm.label("rt_div_fix_half_up")
              asm.lda(asm.direct(R1 + 2))
              asm.and_a(0xFF00)
              asm.bne("rt_div_fix_byte_up")
              asm.lda(asm.direct(R1 + 1))
              asm.sta(asm.direct(R1 + 2))
              asm.lda(asm.direct(R1))
              asm.xba
              asm.and_a(0xFF00)
              asm.sta(asm.direct(R1))
              asm.lda(asm.direct(R2))
              asm.clc
              asm.adc(8)
              asm.sta(asm.direct(R2))
              asm.label("rt_div_fix_byte_up")
              asm.lda(asm.direct(R1 + 2))
              asm.bmi("rt_div_fix_divisor_up")
              asm.label("rt_div_fix_bit_up")
              asm.inc(asm.direct(R2))
              asm.asl(asm.direct(R1))
              asm.rol(asm.direct(R1 + 2))
              asm.bpl("rt_div_fix_bit_up")
              asm.label("rt_div_fix_divisor_up")
            end

            # The numerator, R0, moved up R2 places into the fraction scratch +u+: the rest of R2
            # over 8 a bit at a time, with a fifth byte (in +fifth+) to take what comes over the top,
            # then those five bytes R2 / 8 bytes up, with nought everywhere else.
            def emit_div_fix_spread_numerator(asm, u, fifth)
              (FRACTION_BYTES / 2).times { |i| asm.stz(asm.direct(u + (2 * i))) }
              asm.stz(asm.direct(fifth))
              asm.lda(asm.direct(R2))
              asm.and_a(7)
              asm.beq("rt_div_fix_spread")
              asm.tay
              asm.label("rt_div_fix_widen")
              asm.asl(asm.direct(R0))
              asm.rol(asm.direct(R0 + 2))
              asm.rol(asm.direct(fifth))
              asm.dey
              asm.bne("rt_div_fix_widen")
              asm.label("rt_div_fix_spread")
              asm.lda(asm.direct(R2))
              asm.lsr
              asm.lsr
              asm.lsr
              asm.tax
              asm.lda(asm.direct(R0))
              asm.sta(asm.direct_x(u))
              asm.lda(asm.direct(R0 + 2))
              asm.sta(asm.direct_x(u + 2))
              asm.sep(0x20)
              asm.lda(asm.direct(fifth))
              asm.sta(asm.direct_x(u + 4))
              asm.rep(0x20)
            end

            # The guess at the byte of the quotient X places up, into +guess+: the top two bytes of
            # the five come down, over the divisor's top byte (+top+), on the console's divider; or
            # 255 when the top byte alone is as much as the divisor's, since the guess is a byte.
            def emit_div_fix_guess(asm, u, top, guess)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.lda(asm.direct_x(u + 4))
              asm.cmp(asm.direct(top))
              asm.bcs("rt_div_fix_most")
              asm.rep(0x20)
              asm.lda(asm.direct_x(u + 3))
              asm.sta(asm.abs(h::WRDIVL)) # both bytes, this and WRDIVH
              asm.sep(0x20)
              asm.lda(asm.direct(top))
              asm.sta(asm.abs(h::WRDIVB))
              asm.rep(0x20)
              7.times { asm.nop } # the sixteen cycles the divider takes
              asm.lda(asm.abs(h::RDDIVL))
              asm.bra("rt_div_fix_guessed")
              asm.label("rt_div_fix_most")
              asm.rep(0x20)
              asm.lda(255)
              asm.label("rt_div_fix_guessed")
              asm.sta(asm.direct(guess))
            end

            # The guess times the divisor, into the six bytes at +t+: the divisor's even bytes times
            # the guess into +even+, its odd ones into +odd+ (a byte of nought leaves its product as
            # the nought it was cleared to), and the two added a byte apart.
            def emit_div_fix_product(asm, even, odd, guess, t)
              h = Console::SNESHardware
              asm.sep(0x20)
              asm.lda(asm.direct(guess))
              asm.sta(asm.abs(h::WRMPYA))
              [[0, even], [2, even + 2], [1, odd], [3, odd + 2]].each do |byte, into|
                skip = "rt_div_fix_skip_#{byte}"
                asm.lda(asm.direct(R1 + byte))
                asm.beq(skip)
                asm.sta(asm.abs(h::WRMPYB))
                4.times { asm.nop } # the eight cycles the multiplier takes
                asm.ldy(asm.abs(h::RDMPYL))
                asm.sty(asm.direct(into))
                asm.label(skip)
              end
              asm.rep(0x20)
              asm.lda(asm.direct(odd))
              asm.xba
              asm.and_a(0xFF00)
              asm.clc
              asm.adc(asm.direct(even))
              asm.sta(asm.direct(t))
              asm.lda(asm.direct(odd + 1))
              asm.adc(asm.direct(even + 2))
              asm.sta(asm.direct(t + 2))
              asm.lda(asm.direct(odd + 3))
              asm.and_a(0x00FF)
              asm.adc(0)
              asm.sta(asm.direct(t + 4))
            end

            # The quotient in R0, given its sign and held to the range: past 31 bits it is the highest
            # number, or for a negative answer, past 2^31 the lowest.
            def emit_div_fix_sign_and_clamp(asm, s)
              asm.lda(asm.direct(s.signs))
              asm.eor(asm.direct(s.signs + 1))
              asm.and_a(0x0080)
              asm.bne("rt_div_fix_negative")
              asm.lda(asm.direct(R0 + 2))
              asm.bmi("rt_div_fix_highest")
              asm.rtl
              asm.label("rt_div_fix_negative")
              asm.lda(asm.direct(R0 + 2))
              asm.cmp(0x8000)
              asm.bcc("rt_div_fix_turn")
              asm.bne("rt_div_fix_lowest")
              asm.lda(asm.direct(R0))
              asm.bne("rt_div_fix_lowest")
              asm.label("rt_div_fix_turn")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.rtl
              asm.label("rt_div_fix_too_big")
              asm.lda(asm.direct(s.signs))
              asm.eor(asm.direct(s.signs + 1))
              asm.and_a(0x0080)
              asm.bne("rt_div_fix_lowest")
              asm.label("rt_div_fix_highest")
              asm.lda(0xFFFF)
              asm.sta(asm.direct(R0))
              asm.lda(0x7FFF)
              asm.sta(asm.direct(R0 + 2))
              asm.rtl
              asm.label("rt_div_fix_lowest")
              asm.stz(asm.direct(R0))
              asm.lda(0x8000)
              asm.sta(asm.direct(R0 + 2))
              asm.rtl
            end

            # The 64-bit number at +at+ turned round: every bit flipped and one added.
            def emit_negate_wide(asm, at)
              asm.sec
              4.times do |i|
                asm.lda(0)
                asm.sbc(asm.direct(at + (2 * i)))
                asm.sta(asm.direct(at + (2 * i)))
              end
            end

            # The small routines the ones above share, reached with JSR in the same bank:
            #
            #   rt_make_positive     R0 and R1 made positive, their signs kept: the numerator's in the
            #                        scratch's first sign byte and the divisor's in its second, each
            #                        the top byte of the number (bit 7 the sign)
            #   rt_negate_r0         R0 turned round
            #   rt_sign_half         A = $FFFF when R0's high half is negative, $0000 when it is not
            #   rt_one_signed_like_r0   (JMP, ends with RTL) R0 = -1 when it is negative, 1 when not:
            #                        what dividing by nought gives
            def emit_helpers(asm)
              asm.label("rt_one_signed_like_r0")
              asm.lda(asm.direct(R0 + 2))
              asm.bmi("rt_one_signed_like_r0_minus")
              asm.lda(1)
              asm.sta(asm.direct(R0))
              asm.stz(asm.direct(R0 + 2))
              asm.rtl
              asm.label("rt_one_signed_like_r0_minus")
              asm.lda(0xFFFF)
              asm.sta(asm.direct(R0))
              asm.sta(asm.direct(R0 + 2))
              asm.rtl

              asm.label("rt_negate_r0")
              asm.sec
              asm.lda(0)
              asm.sbc(asm.direct(R0))
              asm.sta(asm.direct(R0))
              asm.lda(0)
              asm.sbc(asm.direct(R0 + 2))
              asm.sta(asm.direct(R0 + 2))
              asm.rts

              asm.label("rt_sign_half")
              asm.lda(asm.direct(R0 + 2))
              asm.bmi("rt_sign_half_minus")
              asm.lda(0)
              asm.rts
              asm.label("rt_sign_half_minus")
              asm.lda(0xFFFF)
              asm.rts
            end

            # rt_make_positive needs to know where the signs go, so it is written with the scratch.
            def emit_make_positive(asm, s)
              asm.label("rt_make_positive")
              asm.sep(0x20)
              asm.lda(asm.direct(R0 + 3))
              asm.sta(asm.direct(s.signs))
              asm.lda(asm.direct(R1 + 3))
              asm.sta(asm.direct(s.signs + 1))
              asm.rep(0x20)
              asm.lda(asm.direct(R0 + 2))
              asm.bpl("rt_make_positive_divisor")
              asm.jsr(asm.abs("rt_negate_r0"))
              asm.label("rt_make_positive_divisor")
              asm.lda(asm.direct(R1 + 2))
              asm.bpl("rt_make_positive_done")
              asm.sec
              asm.lda(0)
              asm.sbc(asm.direct(R1))
              asm.sta(asm.direct(R1))
              asm.lda(0)
              asm.sbc(asm.direct(R1 + 2))
              asm.sta(asm.direct(R1 + 2))
              asm.label("rt_make_positive_done")
              asm.rts
            end
          end
        end
      end
    end
  end
end
