# frozen_string_literal: true

module VBlank
  module IR
    # HOW TO DIVIDE BY A NUMBER WRITTEN IN THE GAME WITHOUT DIVIDING, for a lowering whose machine can
    # multiply two 32-bit numbers and keep the high half of the 64-bit product.
    #
    # A divide is slow on most consoles, or missing: some have no divide instruction at all and call a
    # routine that works the answer out a bit at a time, and those that have one still wait for it far
    # longer than for a multiply. Dividing by a fixed number is the same as multiplying by one over it,
    # and the multiply is quick.
    #
    # One over ten has no exact binary form, so a whole number close to 2**k / 10 stands in for it, and
    # the low k bits of the product are thrown away: the same sum, scaled up and back down. "Close" has
    # to be close ENOUGH: the rounded reciprocal must give exactly the right answer for every one of
    # the four billion numerators, not merely most of them. Rounding up by a hair is safe as long as the
    # hair can never push a numerator over the next whole number, and how big a power of two that needs
    # depends on the divisor.
    #
    # The search below settles it. It is Granlund and Montgomery's method, in the form Hacker's Delight
    # gives: walk k upward and stop at the first k where the error still cannot reach the nearest
    # boundary. The result is a multiplier and a shift exact for the whole 32-bit range, worked out
    # when the game is built, so the console only ever multiplies. Each lowering writes the steps of
    # #quotient in its own machine's instructions; the meaning is Int32.div's, and #quotient is the
    # model they are held to.
    #
    # Where these divisions come from is worth knowing, because most are not the game's own arithmetic.
    # A number on screen is the big one: a score drawn digit by digit is a divide by ten a digit, and the
    # person writing the game wrote `draw_number :score`. The rest is ordinary arithmetic that happens
    # not to land on a power of two: seconds from frames is a divide by 60, a percentage by 100.
    module ConstantDivisor
      WORD = 1 << 32
      SIGN = 1 << 31

      # What dividing by one particular number takes: multiply by +multiplier+, keep the high half of
      # the product, add the numerator back in when +add_numerator+, shift down by +shift+.
      #
      # The addition looks odd and is bookkeeping. For some divisors the multiplier the search finds
      # does not fit in a signed 32-bit register: it wants to be a little over two billion, and a
      # register that size counts to just under. Stored anyway it reads as a negative number, exactly
      # 2**32 too small, and adding the numerator back puts that difference right.
      Recipe = Data.define(:multiplier, :shift, :add_numerator)

      class << self
        # The recipe for dividing by +divisor+, which must be 2 or more. A negative divisor is the same
        # division with the answer negated (truncating is symmetric about nought), a power of two is
        # better as a shift (#power_of_two_bits), and 1, 0 and -1 have no reciprocal worth finding.
        def recipe_for(divisor)
          raise ArgumentError, "a reciprocal needs a divisor of 2 or more, not #{divisor}" if divisor < 2

          multiplier, power = search(divisor)
          Recipe.new(multiplier: multiplier, shift: power - 32, add_numerator: multiplier >= SIGN)
        end

        # How many bits +value+ is a power of two of, for a power of 2 or more; nil for anything else.
        def power_of_two_bits(value)
          return nil unless value > 1 && (value & (value - 1)).zero?

          value.bit_length - 1
        end

        # How many places a divide by the size +size+ is a shift of: 0 for 1, which is the number as
        # it is, and the bits of a power of two; nil for anything else. A lowering that shifts for a
        # power of two asks this, so that a divide or remainder by 1 (or -1) costs no more.
        def shift_bits(size) = size == 1 ? 0 : power_of_two_bits(size)

        # +numerator+ divided by the divisor +recipe+ was made for, truncating toward nought, step by
        # step as a lowering's instructions do it: the high half of the signed product, the numerator
        # added back for a recipe that asks, an arithmetic shift down (which rounds toward minus
        # infinity), and the answer's own sign bit added, which lifts a negative answer one toward
        # nought, as Int32.div rounds.
        def quotient(recipe, numerator)
          high = (Int32.wrap(recipe.multiplier) * numerator) >> 32
          high = Int32.wrap(high + numerator) if recipe.add_numerator
          shifted = high >> recipe.shift
          Int32.wrap(shifted + ((shifted & (WORD - 1)) >> 31))
        end

        private

        # The smallest 2**power whose rounded-up reciprocal of +divisor+ is exact for every 32-bit
        # numerator, as [that reciprocal, power].
        #
        # Two running divisions drive it, both done by hand so they stay exact: 2**p over the divisor
        # (the reciprocal being built), and 2**p over the hardest numerator to get right, the one
        # furthest out in the range that sits closest to a boundary, so if the rounding error clears
        # that one it clears every one. Doubling p is one step of long division on each.
        def search(divisor)
          nearest = SIGN - 1 - (SIGN % divisor)
          power = 31
          tight_q, tight_r = SIGN.divmod(nearest)
          recip_q, recip_r = SIGN.divmod(divisor)

          loop do
            power += 1
            tight_q, tight_r = long_division_step(tight_q, tight_r, nearest)
            recip_q, recip_r = long_division_step(recip_q, recip_r, divisor)
            slack = divisor - recip_r
            break if tight_q > slack || (tight_q == slack && tight_r.positive?)
          end

          [(recip_q + 1) & (WORD - 1), power]
        end

        # One step of long division: double a quotient and its remainder, carrying when the remainder
        # has reached the divisor.
        def long_division_step(quotient, remainder, divisor)
          quotient *= 2
          remainder *= 2
          return [quotient + 1, remainder - divisor] if remainder >= divisor

          [quotient, remainder]
        end
      end
    end
  end
end
