# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # DIVIDING BY A NUMBER WRITTEN IN THE GAME, without the runtime's divide of any two numbers.
          # Mixed into Lowering.
          #
          # The SM83 has no divide and no multiply, so rt_div32 and rt_mod32 do long division a binary
          # digit at a time, the remainder and the divisor four bytes each in memory, and the setting
          # up of both numbers' signs around it. When the divisor is written in the game, most of that
          # is known before the game runs:
          #
          # - A POWER OF TWO is a shift and an AND, written where the sum is.
          # - A BYTE, 3 to 255, is the same long division with what is over held in one register and
          #   the divisor in another (Runtime::Int32#emit_divide_by_byte), which a game carries only
          #   when it divides so. That is the divisor of most of a game's divides: ten for each digit of
          #   a score, sixty for a minute.
          #
          # A reciprocal (IR::ConstantDivisor) needs a multiply of two 32-bit numbers, which here is a
          # routine of its own slower than the division it would stand in for. The Color's own games
          # mostly kept a score in decimal digits to begin with, a nibble each, so they had nothing to
          # divide. Any other divisor still goes to the runtime, and so do 1, 0 and -1.
          module Division
            private

            # `/` by a number written in the program, when it is one worked out here: true when done so.
            def emit_divide_by_number(node)
              divisor = folded(node.rhs)
              size = divisor&.abs
              bits = size && size > 1 && ConstantDivisor.power_of_two_bits(size)
              return false unless bits || byte_divisor?(size)

              value(node.lhs)
              if bits
                emit_quotient_by_power_of_two(bits, size)
              else
                @divides_by_written_bytes = true
                @asm.load(:a, size)
                @asm.call("rt_div32_by_byte")
              end
              @asm.call("rt_neg32") if divisor.negative?
              true
            end

            # `%` by a number written in the program, when it is one worked out here, with Int32.mod's
            # meaning: the sign of the divisor. What is left by the size, from nought up, is counted down
            # from the divisor for a negative one unless it is nought: 1 % -16 is -15. True when done so.
            def emit_remainder_by_number(node)
              divisor = folded(node.rhs)
              size = divisor&.abs
              power = size && size > 1 && ConstantDivisor.power_of_two_bits(size)
              return false unless power || byte_divisor?(size)

              if power
                value(Build.binop(:&, node.lhs, Build.int(size - 1)))
              else
                @divides_by_written_bytes = true
                value(node.lhs)
                @asm.load(:a, size)
                @asm.call("rt_mod32_by_byte")
              end
              emit_counted_down_unless_nought(size) if divisor.negative?
              true
            end

            # A divisor rt_div32_by_byte takes: one that fits a byte and is no power of two.
            def byte_divisor?(size) = size&.between?(3, 0xFF) && !ConstantDivisor.power_of_two_bits(size)

            # BCDE divided by 2**+bits+ (+size+), truncating toward nought. A shift right rounds toward
            # minus infinity, so a number below nought has one less than the size added first: -7 / 2 is
            # (-7 + 1) >> 1, which is -3.
            def emit_quotient_by_power_of_two(bits, size)
              positive = fresh("positive")
              @asm.bit(7, :b)
              @asm.jump_relative(:z, positive)
              emit_bytes_added(size - 1)
              @asm.label(positive)
              emit_shift_in_place(:>>, bits)
            end

            # BCDE less +size+, unless it is nought.
            def emit_counted_down_unless_nought(size)
              nought = fresh("nought")
              emit_upper_bytes_or
              @asm.or_a(:e)
              @asm.jump_relative(:z, nought)
              emit_bytes_added(Int32.neg(Int32.wrap(size)))
              @asm.label(nought)
            end

            # +number+ added to BCDE a byte at a time, the carry walked up.
            def emit_bytes_added(number)
              BCDE_LOW_FIRST.each_with_index do |register, i|
                @asm.load(:a, register)
                byte = (number >> (8 * i)) & 0xFF
                i.zero? ? @asm.add_a(byte) : @asm.adc_a(byte)
                @asm.load(register, :a)
              end
            end
          end
        end
      end
    end
  end
end
