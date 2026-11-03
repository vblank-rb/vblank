# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class SNES
        module Runtime
          # THE SUMS THE SUPER FX CALLS, in its own instructions. A game's number is 32 bits, signed
          # and wrapping (IR::Int32), and the chip's registers are 16, so a number is two of them. Adding
          # is two additions with a carry between them and is written where it is used (SNES::ChipCode);
          # what is here takes a loop, or several steps, and is called.
          #
          # HOW THEY ARE CALLED. With LINK and a jump: the return address in R11, the left number in
          # LOW and HIGH, the right one in RIGHT_LOW and RIGHT_HIGH, and the answer back in LOW and HIGH.
          # A sum may use every other register but R14, whose every write starts a read of the ROM,
          # and R15, the program counter. Nothing here is kept in a register from one sum to the next.
          #
          # THE CHIP HAS ONE-BYTE INSTRUCTIONS, AND A FETCH THAT GOES AHEAD. The byte after a jump or
          # a branch runs whether it is taken or not, and it must be a single byte, since an
          # instruction with a number after it would read that number from where the jump landed.
          # So a NOP goes there.
          #
          # SIGNS. LMULT multiplies signed numbers and the bottom half of a number has no sign, so
          # the product of two bottom halves is put right afterwards. Division here works on sizes
          # alone, and the signs are worked out around it, because IR::Int32 gives the two answers
          # different signs: a quotient rounds toward nought and a remainder takes the divisor's sign.
          module ChipSums
            LOW = 1
            HIGH = 2
            RIGHT_LOW = 3
            RIGHT_HIGH = 5

            MULTIPLY = "chip multiply"
            DIVIDE = "chip divide"
            REMAINDER = "chip remainder"
            SHIFT_LEFT = "chip shift left"
            SHIFT_RIGHT = "chip shift right"
            SIZES = "chip divide sizes"

            # How many bits a number has, and how many are in a register.
            NUMBER_BITS = 32
            HALF_BITS = 16

            module_function

            # The routines of +called+ into +gsu+. +back+ is a word of the chip's RAM that a division
            # keeps its return address in, since it calls SIZES.
            def emit(gsu, called, back:)
              emit_multiply(gsu) if called.include?(MULTIPLY)
              emit_divide(gsu, back) if called.include?(DIVIDE)
              emit_remainder(gsu, back) if called.include?(REMAINDER)
              emit_divide_sizes(gsu) if called.intersect?([DIVIDE, REMAINDER])
              emit_shift_left(gsu) if called.include?(SHIFT_LEFT)
              emit_shift_right(gsu) if called.include?(SHIFT_RIGHT)
            end

            # The registers that hold a number, turned round: nought less it, the low half first with
            # the borrow carried up. R0 is nought for both, since neither subtraction writes it.
            def emit_negate(gsu, low, high)
              gsu.ibt(0, 0)
              gsu.to(low)
              gsu.sub(low)
              gsu.to(high)
              gsu.sbc(high)
            end

            # A jump to +label+ when the register +high+ is below nought.
            def emit_branch_unless_negative(gsu, high, label)
              gsu.moves(0, high)
              gsu.bpl(label)
              gsu.nop
            end

            def emit_size_of(gsu, low, high, label)
              emit_branch_unless_negative(gsu, high, label)
              emit_negate(gsu, low, high)
              gsu.label(label)
            end

            def emit_return(gsu)
              gsu.jmp(11)
              gsu.nop
            end

            # The two bottom halves make the bottom half of the answer and part of the top. LMULT
            # took each as signed, so a half with its top bit set was read as 65536 too few, and
            # that much of the other half is added to the top half of the answer to put it right.
            # Then the top half of each number by the bottom half of the other go into the top half
            # of the answer, whose own top halves are past the end of 32 bits and go nowhere.
            def emit_multiply(gsu)
              gsu.label(MULTIPLY)
              gsu.move(6, RIGHT_LOW)
              gsu.from(LOW)
              gsu.to(7)
              gsu.lmult
              gsu.move(8, 4)
              [[LOW, RIGHT_LOW, "chip multiply left seen"], [RIGHT_LOW, LOW, "chip multiply right seen"]].each do |half, other, seen|
                emit_branch_unless_negative(gsu, half, seen)
                gsu.with(7)
                gsu.add(other)
                gsu.label(seen)
              end
              gsu.from(HIGH)
              gsu.to(0)
              gsu.lmult
              gsu.with(7)
              gsu.add(4)
              gsu.move(6, LOW)
              gsu.from(RIGHT_HIGH)
              gsu.to(0)
              gsu.lmult
              gsu.with(7)
              gsu.add(4)
              gsu.move(LOW, 8)
              gsu.move(HIGH, 7)
              emit_return(gsu)
            end

            # IR::Int32.div: truncated toward nought, so the sizes are divided and the sign put on
            # after; and nought as the divisor gives 1, or -1 for a number below nought.
            def emit_divide(gsu, back)
              gsu.label(DIVIDE)
              emit_branch_unless_nought(gsu, "chip divide by a number")
              emit_branch_unless_negative(gsu, HIGH, "chip divide by nought above")
              gsu.ibt(LOW, -1)
              gsu.ibt(HIGH, -1)
              emit_return(gsu)
              gsu.label("chip divide by nought above")
              gsu.ibt(LOW, 1)
              gsu.ibt(HIGH, 0)
              emit_return(gsu)

              gsu.label("chip divide by a number")
              gsu.sm(back, 11)
              gsu.from(HIGH)
              gsu.to(6)
              gsu.xor(RIGHT_HIGH) # the top bit of R6 now says the signs differ
              emit_size_of(gsu, LOW, HIGH, "chip divide left size")
              emit_size_of(gsu, RIGHT_LOW, RIGHT_HIGH, "chip divide right size")
              emit_call(gsu, SIZES)
              emit_branch_unless_negative(gsu, 6, "chip divide signed")
              emit_negate(gsu, LOW, HIGH)
              gsu.label("chip divide signed")
              gsu.lm(11, back)
              emit_return(gsu)
            end

            # IR::Int32.mod is Ruby's: the answer takes the sign of the divisor, so a number below
            # nought leaves the divisor less what the sizes leave. Nought as the divisor leaves the
            # whole number.
            def emit_remainder(gsu, back)
              gsu.label(REMAINDER)
              emit_branch_unless_nought(gsu, "chip remainder by a number")
              emit_return(gsu)

              gsu.label("chip remainder by a number")
              gsu.sm(back, 11)
              gsu.move(6, HIGH)
              gsu.move(4, RIGHT_HIGH)
              emit_size_of(gsu, LOW, HIGH, "chip remainder left size")
              emit_size_of(gsu, RIGHT_LOW, RIGHT_HIGH, "chip remainder right size")
              emit_call(gsu, SIZES)
              gsu.move(LOW, 9)
              gsu.move(HIGH, 10)
              gsu.from(LOW)
              gsu.to(0)
              gsu.or_(HIGH)
              gsu.beq("chip remainder signed") # nothing left has no sign to take
              gsu.nop
              emit_branch_unless_negative(gsu, 6, "chip remainder left above")
              emit_branch_unless_negative(gsu, 4, "chip remainder from the divisor")
              emit_negate(gsu, LOW, HIGH) # both below nought
              gsu.bra("chip remainder signed")
              gsu.nop
              gsu.label("chip remainder from the divisor") # below nought by a divisor above: size less what is left
              gsu.from(RIGHT_LOW)
              gsu.to(LOW)
              gsu.sub(LOW)
              gsu.from(RIGHT_HIGH)
              gsu.to(HIGH)
              gsu.sbc(HIGH)
              gsu.bra("chip remainder signed")
              gsu.nop
              gsu.label("chip remainder left above")
              emit_branch_unless_negative(gsu, 4, "chip remainder signed")
              gsu.with(LOW) # above nought by a divisor below: what is left less the divisor's size
              gsu.sub(RIGHT_LOW)
              gsu.with(HIGH)
              gsu.sbc(RIGHT_HIGH)
              gsu.label("chip remainder signed")
              gsu.lm(11, back)
              emit_return(gsu)
            end

            # Goes to +label+ unless the right number is nought.
            def emit_branch_unless_nought(gsu, label)
              gsu.from(RIGHT_LOW)
              gsu.to(0)
              gsu.or_(RIGHT_HIGH)
              gsu.bne(label)
              gsu.nop
            end

            def emit_call(gsu, label)
              gsu.link(4)
              gsu.iwt(15, label)
              gsu.nop
            end

            # LONG DIVISION IN BINARY, two sizes at a time from the top: LOW and HIGH (the number)
            # shift left a bit at a time into R9 and R10 (what is left), and each time what is left
            # can spare the divisor, it does, and a 1 goes in at the bottom of the number, which is
            # becoming the quotient. What is left is always below the divisor, which is at most
            # 2**31, so it never runs out of its 32 bits when it doubles.
            #
            # A number that fits its low half is moved up first, which saves sixteen steps of
            # shifting noughts: most numbers in a game are that size.
            #
            # CACHE keeps the loop in the chip's own 512 bytes of quick memory. A byte from there
            # takes one of the chip's cycles and a byte from the ROM takes five. The loop runs up to
            # 32 times, and is worth the one read of each byte from the ROM it takes to fill.
            def emit_divide_sizes(gsu)
              gsu.label(SIZES)
              gsu.ibt(9, 0)
              gsu.ibt(10, 0)
              gsu.ibt(12, NUMBER_BITS)
              gsu.moves(0, HIGH)
              gsu.bne("chip divide wide")
              gsu.nop
              gsu.move(HIGH, LOW)
              gsu.ibt(LOW, 0)
              gsu.ibt(12, HALF_BITS)
              gsu.label("chip divide wide")
              gsu.iwt(13, "chip divide step")
              gsu.cache
              gsu.label("chip divide step")
              gsu.with(LOW)
              gsu.add(LOW)
              [HIGH, 9, 10].each do |register|
                gsu.with(register)
                gsu.rol
              end
              gsu.from(9)
              gsu.to(7)
              gsu.sub(RIGHT_LOW)
              gsu.from(10)
              gsu.to(8)
              gsu.sbc(RIGHT_HIGH)
              gsu.bcc("chip divide short")
              gsu.nop
              gsu.move(9, 7)
              gsu.move(10, 8)
              gsu.inc(LOW)
              gsu.label("chip divide short")
              gsu.loop
              gsu.nop
              emit_return(gsu)
            end

            # IR::Int32.shift_left: a count outside 0 to 31 empties the number. A count of sixteen or
            # more is a move from one half to the other first, so the loop goes round at most fifteen
            # times.
            def emit_shift_left(gsu)
              gsu.label(SHIFT_LEFT)
              emit_count_in_range(gsu, "chip shift left empties")
              emit_branch_unless_half(gsu, "chip shift left part")
              gsu.move(HIGH, LOW)
              gsu.ibt(LOW, 0)
              gsu.label("chip shift left part")
              emit_count_of_steps(gsu, "chip shift left done")
              gsu.iwt(13, "chip shift left step")
              gsu.label("chip shift left step")
              gsu.with(LOW)
              gsu.add(LOW)
              gsu.with(HIGH)
              gsu.rol
              gsu.loop
              gsu.nop
              gsu.label("chip shift left done")
              emit_return(gsu)
              gsu.label("chip shift left empties")
              gsu.ibt(LOW, 0)
              gsu.ibt(HIGH, 0)
              emit_return(gsu)
            end

            # IR::Int32.shift_right: the sign fills in behind, and a count outside 0 to 31 leaves
            # nothing but the sign.
            def emit_shift_right(gsu)
              gsu.label(SHIFT_RIGHT)
              emit_count_in_range(gsu, "chip shift right empties")
              emit_branch_unless_half(gsu, "chip shift right part")
              emit_move_high_half_down(gsu, "chip shift right moved")
              gsu.label("chip shift right part")
              emit_count_of_steps(gsu, "chip shift right done")
              gsu.iwt(13, "chip shift right step")
              gsu.label("chip shift right step")
              gsu.with(HIGH)
              gsu.asr
              gsu.with(LOW)
              gsu.ror
              gsu.loop
              gsu.nop
              gsu.label("chip shift right done")
              emit_return(gsu)
              gsu.label("chip shift right empties")
              gsu.moves(0, HIGH)
              gsu.ibt(LOW, 0)
              gsu.ibt(HIGH, 0)
              gsu.bpl("chip shift right above")
              gsu.nop
              gsu.dec(LOW)
              gsu.dec(HIGH)
              gsu.label("chip shift right above")
              emit_return(gsu)
            end

            # The top half moved down, and the sign filling the top: IBT sets no flags, so the test
            # of the sign still stands after it.
            def emit_move_high_half_down(gsu, label)
              gsu.moves(LOW, HIGH)
              gsu.ibt(HIGH, 0)
              gsu.bpl(label)
              gsu.nop
              gsu.dec(HIGH)
              gsu.label(label)
            end

            # Goes to +outside+ for a count that is not 0 to 31.
            def emit_count_in_range(gsu, outside)
              gsu.moves(0, RIGHT_HIGH)
              gsu.bne(outside)
              gsu.nop
              gsu.ibt(0, NUMBER_BITS)
              gsu.from(RIGHT_LOW)
              gsu.cmp(0)
              gsu.bcs(outside)
              gsu.nop
            end

            # Goes to +label+ for a count below sixteen.
            def emit_branch_unless_half(gsu, label)
              gsu.ibt(0, HALF_BITS)
              gsu.from(RIGHT_LOW)
              gsu.cmp(0)
              gsu.bcc(label)
              gsu.nop
            end

            # R12 the count left below sixteen, for LOOP, which must not start at nought: it would
            # go round 65536 times. Goes to +done+ when there is nothing left to do.
            def emit_count_of_steps(gsu, done)
              gsu.from(RIGHT_LOW)
              gsu.to(12)
              gsu.and_(gsu.imm(HALF_BITS - 1))
              gsu.beq(done)
              gsu.nop
            end
          end
        end
      end
    end
  end
end
