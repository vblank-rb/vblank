# frozen_string_literal: true

require "test_helper"
require "int32_cases"

# A DOS PROGRAM'S ARITHMETIC, in DOSBox, held to the interpreter (DOS::CheckedRun compares every variable):
# the number steps past plain sums, on the values where 32 bits are most likely to go wrong (Int32Cases, the
# table a runtime written again in another language is held to). Each test is one program that works a few
# hundred answers out into variables of their own, from operands kept in variables so that nothing is worked
# out as the game is built.
class TestDOSNumbers < Minitest::Test
  include VBlank::IR::Build

  DOS = VBlank::IR::Backends::DOS
  EDGES = Int32Cases::EDGES
  PAIRS = EDGES.product(EDGES).freeze

  # A program that sets :a, :b and :c to each of +operands+ in turn and stores what the block makes of them,
  # then stops. The block gets the three as values and the name of the answer's variable.
  private def answers_of(operands)
    statements = operands.each_with_index.flat_map do |(a, b, c), i|
      [set(:a, int(a)), set(:b, int(b || 0)), set(:c, int(c || 0)), *Array(yield(var_ref(:a), var_ref(:b), var_ref(:c), :"r#{i}"))]
    end
    DOS::CheckedRun.new.run(program(screen(:bitmap), *statements, halt, console: :dos))
  end

  # The run agreed with the interpreter on every variable; this holds the interpreter's to Int32Cases'
  # own answer too, so the test says what the numbers should be and not only that two builds agree.
  private def assert_answers(run, operands, name, third = nil)
    operands.each_with_index do |(a, b, c), i|
      assert_equal Int32Cases.expected(name, a, b || 0, third || c || 0), run[:"r#{i}"], "#{name} of #{a}, #{b}, #{third || c}"
    end
  end

  def test_products_of_numbers_that_hold_fractions
    Int32Cases::FRACTION_BITS.each do |bits|
      run = answers_of(PAIRS) { |a, b, _, answer| set(answer, mul_fix(a, b, bits)) }

      assert_answers(run, PAIRS, "mul_fix", bits)
    end
  end

  def test_quotients_of_numbers_that_hold_fractions
    Int32Cases::FRACTION_BITS.each do |bits|
      run = answers_of(PAIRS) { |a, b, _, answer| set(answer, div_fix(a, b, bits)) }

      assert_answers(run, PAIRS, "div_fix", bits)
    end
  end

  def test_shifts_right_by_a_count_settled_as_the_game_is_built
    Int32Cases::SHIFTS.select { |count| count.between?(0, 31) }.each do |count| # the counts a tree can hold
      operands = EDGES.map { |a| [a, count] }
      run = answers_of(operands) { |a, _, _, answer| set(answer, shift_right(a, count)) }

      assert_answers(run, operands, "shift_right")
    end
  end

  def test_a_number_the_other_way_round_its_bits_flipped_and_how_far_it_is_from_nought
    operands = EDGES.zip
    run = answers_of(operands) do |a, _, _, answer|
      [set(answer, absolute(a)), set(:"n#{answer}", bit_not(a)), set(:"v#{answer}", a), negate(:"v#{answer}"),
       set(:"p#{answer}", a), abs(:"p#{answer}"), set(:"m#{answer}", a), negate_abs(:"m#{answer}")]
    end

    assert_answers(run, operands, "abs")
    operands.each_with_index do |(a), i|
      size = Int32Cases.expected("abs", a, 0, 0)

      assert_equal [Int32Cases.expected("bit_not", a, 0, 0), Int32Cases.expected("neg", a, 0, 0), size, a.positive? ? Int32Cases.expected("neg", a, 0, 0) : a],
                   [run[:"nr#{i}"], run[:"vr#{i}"], run[:"pr#{i}"], run[:"mr#{i}"]], "of #{a}"
    end
  end

  # A number held inside a range, as a new number and as a variable changed: floors above their ceilings too.
  def test_a_number_held_inside_a_range
    operands = EDGES.product([-64, 0, 98_304], [-129, 7, Int32Cases::Int32::MAX])
    run = answers_of(operands) do |a, b, c, answer|
      [set(answer, clamped(a, b, c)), set(:"v#{answer}", a), clamp(:"v#{answer}", b, c)]
    end

    assert_answers(run, operands, "clamp")
    operands.each_index { |i| assert_equal run[:"r#{i}"], run[:"vr#{i}"] }
  end
end
