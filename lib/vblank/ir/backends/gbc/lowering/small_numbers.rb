# frozen_string_literal: true

module VBlank
  module IR
    module Backends
      class GBC
        class Lowering
          # NUMBERS PROVEN TO STAY IN ONE OR TWO BYTES (Backends::NumberRanges), compared and worked
          # at that width. Mixed into Lowering.
          #
          # The Color's processor works a byte at a time, so a comparison of two whole numbers is the
          # runtime's rt_cmp32: three registers kept on the stack and four bytes subtracted, a few
          # hundred cycles where the console's own games compare a byte with one `cp` (Pan Docs,
          # "CPU Instruction Set"). A number whose bytes above its lowest one or two hold only its
          # sign is that byte or two, so comparing them gives the same answer: one `cp` for two
          # numbers from 0 to 255; the same with each sign bit turned over first for two from -128 to
          # 127, so the negative ones come below the rest; a subtraction of two bytes, the top one's
          # sign bit turned over, for two that fit 16 bits. A size (`abs`) or a shift down of such a
          # number is worked in its two bytes too (#low_value).
          #
          # What every number means is unchanged: these give IR::Int32's answer.
          module SmallNumbers
            private

            # The carry set when +operand+'s number, proven small, is below +number+, a number written
            # in the program, and clear when not: true when it was done so. A number the range is all
            # below, or all at or above, needs nothing worked out.
            def emit_carry_when_proven_below(operand, number)
              range = proven_range(operand) or return false
              if range.end < number
                @asm.scf
              elsif range.begin >= number
                @asm.scf
                @asm.ccf
              elsif range.begin >= 0 && range.end <= 0xFF
                emit_low_byte_in_a(operand)
                @asm.cp_a(number)
              elsif proven_within?(operand, NumberRanges::BYTE)
                emit_low_byte_in_a(operand)
                @asm.xor_a(0x80)
                @asm.cp_a((number & 0xFF) ^ 0x80)
              elsif proven_within?(operand, NumberRanges::HALF)
                low_value(operand, 2)
                @asm.load(:a, :d)
                @asm.xor_a(0x80)
                @asm.load(:h, :a) # a load moves no flag, so the borrow from the low byte is kept
                @asm.load(:a, :e)
                @asm.sub_a(number & 0xFF)
                @asm.load(:a, :h)
                @asm.sbc_a(((number >> 8) & 0xFF) ^ 0x80)
              else
                return false
              end
              true
            end

            # TWO SIDES OF A COMPARISON PROVEN TO FIT THE SAME BYTE OR TWO: [the width, :byte for
            # two from 0 to 255, :signed_byte for two from -128 to 127, or :half for two that fit 16
            # bits], or nil.
            def small_sides_width(left, right)
              return :byte if [left, right].all? { |side| proven_within?(side, 0..0xFF) }
              return :signed_byte if [left, right].all? { |side| proven_within?(side, NumberRanges::BYTE) }

              :half if [left, right].all? { |side| proven_within?(side, NumberRanges::HALF) }
            end

            # An ordering (<, <=, >, >=) of two sides proven small: [the one, the other, whether it
            # holds when the one is below the other, the width (#small_sides_width)], or nil.
            def small_ordering(condition)
              return nil unless condition.is_a?(Node) && condition.kind == :binop && %i[< <= > >=].include?(condition.op)

              left, right = condition.lhs, condition.rhs
              one, other, below = case condition.op
                                  when :< then [left, right, true]
                                  when :>= then [left, right, false]
                                  when :> then [right, left, true]
                                  else [right, left, false]
                                  end
              width = small_sides_width(one, other)
              [one, other, below, width] if width
            end

            # An equality (==, !=) of two sides proven small: [the one, the other, the width], or nil.
            def small_equality(condition)
              return nil unless binop?(condition, :==) || binop?(condition, :!=)

              width = small_sides_width(condition.lhs, condition.rhs)
              [condition.lhs, condition.rhs, width] if width
            end

            # The carry set when +one+ is below +other+, both proven small at +width+. The other side
            # is worked out first and kept on the stack, as a sum of four bytes keeps its right side.
            def emit_carry_when_small_below(one, other, width)
              return emit_carry_when_half_below(one, other) if width == :half

              emit_low_bytes_of_pair(one, other, 1)
              if width == :signed_byte
                # Each sign bit turned over, so the negative numbers come below the rest.
                @asm.xor_a(0x80)
                @asm.load(:l, :a)
                @asm.load(:a, :h)
                @asm.xor_a(0x80)
                @asm.load(:h, :a)
                @asm.load(:a, :l)
              end
              @asm.cp_a(:h)
            end

            # The zero flag set when +one+ and +other+, both proven small at +width+, are equal.
            def emit_zero_when_small_equal(one, other, width)
              if width == :half
                done = fresh("compared")
                emit_low_bytes_of_pair(one, other, 2)
                @asm.load(:a, :e)
                @asm.cp_a(:l)
                @asm.jump_relative(:nz, done)
                @asm.load(:a, :d)
                @asm.cp_a(:h)
                return @asm.label(done)
              end

              emit_low_bytes_of_pair(one, other, 1)
              @asm.cp_a(:h)
            end

            def emit_carry_when_half_below(one, other)
              emit_low_bytes_of_pair(one, other, 2)
              @asm.load(:a, :h)
              @asm.xor_a(0x80)
              @asm.load(:h, :a)
              @asm.load(:a, :d)
              @asm.xor_a(0x80)
              @asm.load(:d, :a)
              @asm.load(:a, :e)
              @asm.sub_a(:l)
              @asm.load(:a, :d)
              @asm.sbc_a(:h)
            end

            # The low +bytes+ of +one+ and +other+: for one byte, +one+'s in A and +other+'s in H; for
            # two, +one+'s in DE and +other+'s in HL.
            def emit_low_bytes_of_pair(one, other, bytes)
              if bytes == 1
                emit_low_byte_in_a(other)
                @asm.push(:af)
                emit_low_byte_in_a(one)
              else
                low_value(other, 2)
                @asm.push(:de)
                low_value(one, 2)
              end
              @asm.pop(:hl) # a pop of what AF held puts A in H, and moves no flag
            end

            # E and D = the low two bytes of the size of +operand+'s number, which is proven to fit
            # 16 bits: the two bytes turned round when the top one's sign bit is set. The most
            # negative such, -32768, has the size 32768, whose low two bytes are what turning it
            # round gives.
            def emit_low_bytes_of_half_size(operand)
              done = fresh("positive")
              low_value(operand, 2)
              @asm.bit(7, :d)
              @asm.jump_relative(:z, done)
              @asm.xor_a(:a)
              @asm.sub_a(:e)
              @asm.load(:e, :a)
              @asm.load(:a, 0) # a load moves no flag, so the borrow is kept
              @asm.sbc_a(:d)
              @asm.load(:d, :a)
              @asm.label(done)
            end

            # E and D = the low two bytes of +operand+'s number, proven to fit 16 bits, shifted down
            # by +count+, the sign coming in at the top. Fifteen places or more leave only the sign.
            def emit_low_bytes_of_half_shifted(operand, count)
              low_value(operand, 2)
              [count, 15].min.times do
                @asm.sra(:d)
                @asm.rr(:e)
              end
            end
          end
        end
      end
    end
  end
end
