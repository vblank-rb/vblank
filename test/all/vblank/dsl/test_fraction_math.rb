# frozen_string_literal: true

require "test_helper"

# The game these tests play, shared with the Advance cartridge's own test of the same answer
# (test/lowering/gba/vblank/dsl/test_fraction_math_cartridge.rb).
module FractionMathGames
  include SharedConstants

  ONE = 65_536          # 1.0, with 16 fraction bits
  ONE_AND_A_HALF = 3 * ONE / 2
  MARKER_Y = 40
  PER_UNIT = ONE / 20   # the marker moves 20 pixels per whole unit, so 2.25 -> x 45

  # Multiply the two numbers the given way and park a marker at the answer, scaled
  # down to pixels. `plain` picks the ordinary `*` instead, to show what it does.
  private def marker_program(plain: false)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      a = var :a, ONE_AND_A_HALF
      product = var :product, 0
      product = plain ? a * a : a.times_fraction(a, fraction_bits: 16)
      x = var :x, 0
      x = product / PER_UNIT
      draw_rect_at x, MARKER_Y, 4, 4, Color.resolve(:white)
      halt
    end
    b.finalize_program
    b.program
  end
end

# Multiplying two numbers that hold a fraction (`times_fraction`).
#
# A variable holds whole numbers, so a program that needs halves keeps its numbers
# multiplied up — with 16 fraction bits, 1.5 is stored as 98304. Adding those works
# already. Multiplying them does not: the answer comes out multiplied up twice, and
# that intermediate is bigger than a variable can hold, so a plain `*` wraps and
# returns nonsense.
#
# These tests put the answer on screen as a marker, so what is asserted is where the
# marker landed — which is exactly what a game would get wrong. Where it lands on the Advance's
# cartridge is in test/lowering/gba/vblank/dsl/test_fraction_math_cartridge.rb.
class TestFractionMath < Minitest::Test
  include FractionMathGames

  # 1.5 * 1.5 is 2.25, so the marker stands at x 45. Getting there needs a product of
  # 9,663,676,416 on the way — four times what a variable can hold.
  def test_the_answer_lands_where_it_should_on_the_interpreter
    screen = game_player.run(marker_program).screen

    assert_equal Color.resolve(:white), screen.pixel(45, MARKER_Y), "1.5 * 1.5 puts the marker at 2.25"
    assert_equal 0, screen.pixel(41, MARKER_Y), "and nowhere near 2.0"
  end

  # The reason the operation exists: a plain `*` on the same two numbers overflows,
  # and the marker goes somewhere else entirely — here, right off the screen. Both
  # backends have to be wrong the SAME way, which is what makes this a fair contrast
  # rather than a claim about one of them.
  def test_a_plain_multiply_overflows_and_loses_the_marker
    screen = game_player.run(marker_program(plain: true)).screen
    on_screen = (0...240).select { |x| screen.pixel(x, MARKER_Y) == Color.resolve(:white) }

    assert_empty on_screen, "the wrapped product puts the marker off screen"
  end

  # Both operands multiplied up by the same amount, one of them negative.
  def test_a_negative_operand_keeps_its_sign
    prog = VBlank::IR::Build.program(
      VBlank::IR::Build.set(:out, VBlank::IR::Build.mul_fix(
                                     VBlank::IR::Build.int(-ONE_AND_A_HALF),
                                     VBlank::IR::Build.int(ONE_AND_A_HALF), 16
                                   )),
      VBlank::IR::Build.halt,
    )

    assert_equal(-(2.25 * ONE), game_player.run(prog)[:out])
  end

  MIN = -0x8000_0000
  MAX = 0x7FFF_FFFF

  # The awkward ends of multiplying: -1.0 times the lowest number is one past the highest, and wraps
  # back round to the lowest; a product past 32 bits keeps its low bits (2**30 * 2**30 brought down by
  # 16 is 2**44, whose low 32 bits are nought); and a negative product too small to show rounds DOWN, to
  # -1, while the positive one rounds to nought.
  def test_a_product_too_big_wraps_and_a_negative_one_rounds_down
    run = game_player.run(fraction_program(
                            minus_one_times_lowest: [:mul_fix, MIN, -ONE, 16],
                            past_32_bits: [:mul_fix, 1 << 30, 1 << 30, 16],
                            tiny_negative: [:mul_fix, -1, 1, 16],
                            tiny_positive: [:mul_fix, 1, 1, 16],
                            whole_numbers: [:mul_fix, -7, 6, 0],
                            top_half_alone: [:mul_fix, 1 << 30, -8, 32]
                          ))

    assert_equal MIN, run[:minus_one_times_lowest]
    assert_equal 0, run[:past_32_bits]
    assert_equal(-1, run[:tiny_negative])
    assert_equal 0, run[:tiny_positive]
    assert_equal(-42, run[:whole_numbers])
    assert_equal(-2, run[:top_half_alone], "2**30 * -8 is -2**33, and its top 32 bits are -2")
  end

  # Dividing: toward nought, never down (-1.0 / 3 is -0.33333, not -0.33334); an answer too big to hold
  # is held at the end of the range (1.0 over the smallest fraction is 2**32), and so is the lowest number
  # over -1, which a plain divide wraps; nought as the divisor gives 1, or -1 for a numerator below
  # nought, and 1 for nought over nought.
  def test_a_quotient_truncates_toward_nought_and_holds_at_the_ends
    run = game_player.run(fraction_program(
                            minus_a_third: [:div_fix, -ONE, 3 * ONE, 16],
                            over_smallest: [:div_fix, ONE, 1, 16],
                            under_smallest: [:div_fix, ONE, -1, 16],
                            lowest_over_minus_one: [:div_fix, MIN, -1, 0],
                            over_nought: [:div_fix, 3 * ONE, 0, 16],
                            negative_over_nought: [:div_fix, -3 * ONE, 0, 16],
                            nought_over_nought: [:div_fix, 0, 0, 16],
                            near_nought: [:div_fix, ONE_AND_A_HALF, -3, 16],
                            three_over_one_and_a_half: [:div_fix, 3 * ONE, ONE_AND_A_HALF, 16],
                            highest_over_highest: [:div_fix, MAX, MAX, 31]
                          ))

    assert_equal(-21_845, run[:minus_a_third])
    assert_equal MAX, run[:over_smallest]
    assert_equal MIN, run[:under_smallest]
    assert_equal MAX, run[:lowest_over_minus_one]
    assert_equal 1, run[:over_nought]
    assert_equal(-1, run[:negative_over_nought])
    assert_equal 1, run[:nought_over_nought]
    assert_equal MIN, run[:near_nought], "1.5 over -3/65536 is exactly the lowest number"
    assert_equal 2 * ONE, run[:three_over_one_and_a_half]
    assert_equal MAX, run[:highest_over_highest], "1.0 with 31 bits of fraction does not fit"
  end

  # fraction_bits is settled while building, so a nonsensical one is a build error
  # rather than a ROM that shifts by a number the chip cannot encode.
  def test_an_impossible_number_of_fraction_bits_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      VBlank::IR::Build.mul_fix(VBlank::IR::Build.int(1), VBlank::IR::Build.int(1), 33)
    end
    assert_match(/fraction_bits/, err.message)
    assert_match(/0 to 32/, err.message)
  end

  private

  # A program that sets a variable for each name to [kind, a, b, bits] worked out. The two numbers are
  # variables first, so no build can work the answer out ahead of the game.
  def fraction_program(sums)
    build = VBlank::IR::Build
    statements = sums.flat_map do |name, (kind, a, b, bits)|
      [build.set(:"#{name}_a", a), build.set(:"#{name}_b", b),
       build.set(name, build.public_send(kind, build.var_ref(:"#{name}_a"), build.var_ref(:"#{name}_b"), bits))]
    end
    build.program(*statements, build.halt)
  end
end
