# frozen_string_literal: true

require "test_helper"
require "stringio"

# What multiplying and dividing two numbers with a fraction costs on the Super Nintendo, read from
# where bsnes says the time went. The answers are test_snes_int32's; this is that both go through
# the console's own multiplier and divider a byte at a time. Worked a bit at a time, as they were,
# each cost several times the bounds here, and a frame held fewer than ten divides.
class TestSNESFractionCost < Minitest::Test
  CALLS_A_PASS = 8
  CLOCKS_A_FRAME = VBlank::Console.described(:snes).cycles_a_frame

  # The routines a fraction's multiply or divide runs, with the ones they share.
  ROUTINES = /\Art_(mul_fix|div_fix|make_positive|negate_r0|one_signed_like_r0)/

  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  # Each pass works out +sum+ of two numbers kept in variables CALLS_A_PASS times, so that nothing
  # is worked out when the game is built.
  private def summing(first, second)
    calls = CALLS_A_PASS
    VBlank.game("FRACTIONS", consoles: %i[snes]) do
      n = var :n, first
      d = var :d, second
      total = var :total, 0.0
      game_loop do
        repeat(calls) { total = yield(n, d) }
      end
    end
  end

  # The master clocks one sum spent in the routines, the call to them and the loop around them left
  # out, over every frame measured: a pass too slow for one frame is counted whole.
  private def clocks_a_call(game)
    result = rom_of(game).profile(out: StringIO.new, settle: 4, frames: 12)
    share = result.runtime.select { |spent| spent.routine.to_s.match?(ROUTINES) }.sum(&:share)
    (share * CLOCKS_A_FRAME * result.frames / (result.passes * CALLS_A_PASS)).round
  end

  # 50.25 times 3.5: three bytes by two that are not nought, so six of the console's products.
  def test_a_multiply_costs_its_products
    clocks = clocks_a_call(summing(50.25, 3.5) { |n, d| n * d })

    assert_operator clocks, :<, 3_500, "a multiply took #{clocks} master clocks"
  end

  # The same with one of them below nought: the product is turned round before it is brought down.
  def test_a_negative_multiply_costs_little_more
    clocks = clocks_a_call(summing(-50.25, 3.5) { |n, d| n * d })

    assert_operator clocks, :<, 4_000, "a multiply took #{clocks} master clocks"
  end

  # 50.25 over 3.5: a quotient of twenty bits, three bytes, each a guess on the divider and one
  # product, since 3.5 moved up to its top bit is a byte and three of nought.
  def test_a_divide_costs_a_step_a_byte
    clocks = clocks_a_call(summing(50.25, 3.5) { |n, d| n / d })

    assert_operator clocks, :<, 11_000, "a divide took #{clocks} master clocks"
  end

  # 50.25 over 3.3: the divisor moved up has two bytes that are not nought, so two products a step.
  def test_a_divide_by_a_longer_divisor_costs_a_product_more_a_step
    clocks = clocks_a_call(summing(50.25, 3.3) { |n, d| n / d })

    assert_operator clocks, :<, 12_000, "a divide took #{clocks} master clocks"
  end

  def test_a_game_with_no_fractions_carries_no_fraction_routines
    game = VBlank.game("WHOLE NUMBERS", consoles: %i[snes]) do
      total = var :total, 3
      game_loop { total *= total }
    end

    routines = rom_of(game).built.code.keys
    refute_includes routines, "rt_mul_fix"
    refute_includes routines, "rt_div_fix"
  end

  def test_a_game_with_fractions_carries_their_routines
    game = VBlank.game("FRACTIONS", consoles: %i[snes]) do
      n = var :n, 1.5
      total = var :total, 0.0
      game_loop { total = n * n }
    end

    assert_includes rom_of(game).built.code.keys, "rt_mul_fix"
  end
end
