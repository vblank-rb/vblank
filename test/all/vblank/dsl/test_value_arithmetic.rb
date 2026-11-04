# frozen_string_literal: true

require "test_helper"

# A game's numbers at the edges of IR::Int32, each worked out by the game from variables it keeps, so
# no build can work the answer out for itself: wrapping past the 32-bit ends, dividing and taking the
# remainder by nought, by -1 and by a negative number, and shifting by 32 or by -1. A console's
# processor gets several of these wrong on its own (the R3000 divides by nought to the opposite sign,
# and shifts by the low five bits of the count alone), so each lowering has to put them right.
class TestValueArithmetic < Minitest::Test
  private def played(frames: 2, &game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    game_player.run(builder.program, frames: frames)
  end

  # The numbers each game works from, set again on every pass to what they were, so each is a variable.
  private def edges
    played do
      lowest = 0
      zero = 0
      minus_one = 0
      seven = 0
      over = 0
      by_zero = 0
      below_by_zero = 0
      zero_by_zero = 0
      left_by_zero = 0
      left_below = 0
      left_by_below = 0
      lowest_over = 0
      lowest_left = 0
      shifted_out = 0
      shifted_down = 0
      shifted_back = 0
      turned = 0
      wrapped = 0
      game_loop do
        zero = seven - seven
        seven = zero + 7
        minus_one = zero - 1
        over = zero + 32
        lowest = (zero - 2_147_483_647) - 1
        by_zero = seven / zero
        below_by_zero = (zero - seven) / zero
        zero_by_zero = zero / zero
        left_by_zero = seven % zero
        left_below = (zero - seven) % 3
        left_by_below = seven % (zero - 3)
        lowest_over = lowest / minus_one
        lowest_left = lowest % minus_one
        shifted_out = seven << over
        shifted_down = (zero - seven) >> over
        shifted_back = seven << minus_one
        turned = lowest * minus_one
        wrapped = (lowest + seven) * 65_537
      end
    end
  end

  def test_dividing_by_nought_gives_one_with_the_numerators_sign
    run = edges

    assert_equal [1, -1, 1], [run[:by_zero], run[:below_by_zero], run[:zero_by_zero]]
  end

  def test_the_remainder_takes_the_divisors_sign_and_by_nought_is_the_number
    run = edges

    assert_equal [7, 2, -2], [run[:left_by_zero], run[:left_below], run[:left_by_below]]
  end

  def test_the_lowest_number_over_minus_one_and_times_minus_one_wraps_to_itself
    run = edges

    assert_equal [-2_147_483_648, 0, -2_147_483_648], [run[:lowest_over], run[:lowest_left], run[:turned]]
  end

  def test_a_shift_by_32_or_by_minus_one_empties_the_number
    run = edges

    assert_equal [0, -1, 0], [run[:shifted_out], run[:shifted_down], run[:shifted_back]]
  end

  def test_a_product_past_the_32_bit_ends_wraps
    run = edges

    assert_equal(-2_147_024_889, run[:wrapped])
  end

  def test_sums_and_products_past_the_ends_wrap
    run = played do
      big = 0
      doubled = 0
      tripled = 0
      game_loop do
        big = (big * 0) + 2_000_000_000
        doubled = big + big
        tripled = big * 3
      end
    end

    assert_equal [-294_967_296, 1_705_032_704], [run[:doubled], run[:tripled]]
  end

  # What is left after dividing by a power of two takes the divisor's sign, as Ruby's `%` does.
  def test_what_is_left_by_a_power_of_two_takes_the_divisors_sign
    run = played do
      a = 0
      by_two = 0
      by_sixteen = 0
      by_1024 = 0
      by_two_to_the_thirty = 0
      b = 0
      game_loop do
        a = (a * 0) - 1
        b = a - 2_000_036
        by_two = a % 2
        by_sixteen = a % 16
        by_1024 = a % 1024
        by_two_to_the_thirty = b % 1_073_741_824
      end
    end

    assert_equal [1, 15, 1023, 1_071_741_787], [run[:by_two], run[:by_sixteen], run[:by_1024], run[:by_two_to_the_thirty]]
  end

  def test_comparisons_clamps_and_turning_round
    run = played do
      a = 0
      flags = 0
      held = 0
      size = 0
      game_loop do
        a = (a * 0) - 7
        held = a.clamp(-5, 5)
        size = a.abs - a.flip
        flags = 0
        flags += 1 if a < 0
        flags += 2 if a <= held
        flags += 4 if a > -8
        flags += 8 if a >= held
        flags += 16 if a == -7
        flags += 32 if a != 7
      end
    end

    assert_equal [-5, 0, 1 + 2 + 4 + 16 + 32], [run[:held], run[:size], run[:flags]]
  end
end
