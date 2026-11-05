# frozen_string_literal: true

require "test_helper"

# DIVIDING BY A NUMBER WRITTEN IN THE GAME (IR::ConstantDivisor): a lowering may multiply by a
# reciprocal worked out when the game is built rather than divide, and a shift does for a power of
# two. Either way the answer is Int32.div's and Int32.mod's, for every numerator, the most negative
# included, and for every divisor's sign.
class TestConstantDivisor < Minitest::Test
  include VBlank::IR::Build

  Int32 = VBlank::IR::Int32
  ConstantDivisor = VBlank::IR::ConstantDivisor

  # --- the recipe, in Ruby ---------------------------------------------------------------------------

  # Numerators worth trying for one divisor: the ends of the range, and both sides of enough exact
  # multiples that an off-by-one in the rounding cannot hide.
  private def numerators(divisor)
    edges = [0, 1, -1, Int32::MIN, Int32::MAX, Int32::MIN + 1, Int32::MAX - 1]
    boundaries = (1..30).flat_map { |k| [(k * divisor) - 1, k * divisor, (k * divisor) + 1] }
    spread = Random.new(divisor).then { |r| Array.new(60) { r.rand(Int32::MIN..Int32::MAX) } }
    (edges + boundaries + boundaries.map(&:-@) + spread).uniq.select { |n| n.between?(Int32::MIN, Int32::MAX) }
  end

  # The claim the whole feature rests on: the reciprocal is not an approximation that is usually
  # right, it is exactly right for every numerator.
  def test_the_recipe_divides_exactly_for_every_numerator
    divisors = (2..120).to_a + [200, 641, 1000, 3600, 60_000, 100_000, 1 << 30, Int32::MAX]
    checked = 0
    divisors.each do |divisor|
      recipe = ConstantDivisor.recipe_for(divisor)
      numerators(divisor).each do |n|
        checked += 1

        assert_equal Int32.div(n, divisor), ConstantDivisor.quotient(recipe, n), "#{n} / #{divisor}"
      end
    end
    assert_operator checked, :>, 20_000, "the sweep should be wide enough to mean something"
  end

  def test_a_divisor_below_two_has_no_recipe
    [1, 0, -10].each do |divisor|
      error = assert_raises(ArgumentError) { ConstantDivisor.recipe_for(divisor) }

      assert_match(/2 or more/, error.message)
    end
  end

  def test_a_power_of_two_is_known_by_its_bits
    assert_equal [1, 4, 30, 31], [2, 16, 1 << 30, 1 << 31].map { |value| ConstantDivisor.power_of_two_bits(value) }
    assert_equal [nil, nil, nil, nil], [1, 0, 10, -16].map { |value| ConstantDivisor.power_of_two_bits(value) }
  end

  # --- the game, on every lowering -------------------------------------------------------------------

  NUMERATORS = [
    0, 1, -1, 7, -7, 9, -9, 10, -10, 99, -99, 100, -100, 3599, -3599, 12_345, -12_345, 0x7FFF, -0x8000,
    0x1234_5678, -0x1234_5678, Int32::MAX, Int32::MIN, Int32::MIN + 1, Int32::MAX - 1
  ].freeze

  # Every sign, the digit and the minute, a divisor needing the numerator added back (7, 60), the top of
  # a byte (255: what is over passes a byte as a byte-wide division goes), powers of two both ways, the
  # ends of the range, and the three left to a divide routine (1, 0, -1).
  DIVISORS = [3, -3, 7, 10, -10, 60, 100, 255, 641, 1000, 4, -4, 16, -16, 1 << 30, Int32::MAX, Int32::MIN, 1, 0, -1].freeze

  def test_dividing_by_a_written_number_gives_what_int32_gives
    wrong = wrong_answers(:/) { |n, d| Int32.div(n, d) }

    assert_empty wrong.first(20), "#{wrong.size} quotients were wrong; the first of them are listed"
  end

  def test_the_remainder_by_a_written_number_gives_what_int32_gives
    wrong = wrong_answers(:%) { |n, d| Int32.mod(n, d) }

    assert_empty wrong.first(20), "#{wrong.size} remainders were wrong; the first of them are listed"
  end

  private

  # Each answer to `v op d` the game got wrong, said for a person: the game takes the next numerator
  # each pass and works out the sum for every one of DIVISORS.
  def wrong_answers(op)
    names = DIVISORS.each_index.map { |k| :"answer#{k}" }
    game = program(
      screen(:bitmap),
      table(:numerators, NUMERATORS, width: :word, signed: true),
      set(:pass, 0),
      loop_(
        set(:v, table_get(:numerators, var_ref(:pass))),
        *DIVISORS.zip(names).map { |d, name| set(name, binop(op, var_ref(:v), int(d))) },
        add(:pass, 1),
        wait_vblank
      )
    )
    seen = []
    player = game_player
    player.each_vblank { seen << names.map { |name| player[name] } }
    player.run(game, frames: NUMERATORS.length)
    NUMERATORS.each_with_index.flat_map do |n, pass|
      DIVISORS.each_with_index.filter_map do |d, k|
        want = yield(n, d)
        got = seen.fetch(pass)[k]
        "#{n} #{op} #{d} gave #{got}, not #{want}" unless got == want
      end
    end
  end
end
