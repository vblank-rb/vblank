# frozen_string_literal: true

require "test_helper"

# Numbers that hold a fraction, worked out by R3000 code on 64 bits: each pass multiplies and divides a pair
# of numbers read from tables, at every fraction size the routines treat differently (none, one, a byte,
# the usual sixteen, 31 and all 32). The check is PS1::CheckedRun's: it plays the same passes on the
# interpreter and compares every variable after each one, so one number out by one anywhere fails the pass
# it first differs on. The pairs are the awkward ones: both signs, the lowest and highest numbers, nought,
# divisors near nought, and products and quotients too big for 32 bits.
class TestPS1Fractions < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1

  # 0x0FFF_FFFF is the biggest number of 28 bits: big enough that its products pass 32 bits at every size
  # of fraction, and not one of the ends of the range, which are here already.
  EDGES = [0, 1, -1, 2, -2, 3, -3, 65_536, -65_536, 98_304, -98_304, 123_456_789, -123_456_789, 0x7FFFFFFF,
           -0x80000000, 0x40000000, -0x40000000, 255, -255, 46_341, 65_535, 0x0FFF_FFFF].freeze
  PAIRS = EDGES.product(EDGES).freeze
  # The same numbers as a game writes them with a fraction: each is the edge over 2**16, exactly.
  ONE = 65_536.0

  def test_products_and_quotients_of_fractions_agree_with_the_interpreter_on_the_awkward_pairs
    firsts = PAIRS.map(&:first)
    seconds = PAIRS.map(&:last)
    program = program_of do
      screen :bitmap
      as = table :as, firsts, width: :word
      bs = table :bs, seconds, width: :word
      fraction_as = table :fraction_as, firsts.map { |n| n / ONE }, width: :word
      fraction_bs = table :fraction_bs, seconds.map { |n| n / ONE }, width: :word
      i = 0
      times = 0.0
      over = 0.0
      whole_over = 0.0
      mul0 = 0
      mul1 = 0
      mul8 = 0
      mul31 = 0
      mul32 = 0
      div0 = 0
      div1 = 0
      div8 = 0
      div31 = 0
      game_loop do
        a = as[i]
        b = bs[i]
        # Sixteen bits, as a game writes it: a Float in a Value, `*` and `/`. A whole number over a
        # fraction is widened by both scales, 32 bits.
        times = fraction_as[i] * fraction_bs[i]
        over = fraction_as[i] / fraction_bs[i]
        whole_over = a / fraction_bs[i]
        mul0 = a.times_fraction(b, fraction_bits: 0)
        mul1 = a.times_fraction(b, fraction_bits: 1)
        mul8 = a.times_fraction(b, fraction_bits: 8)
        mul31 = a.times_fraction(b, fraction_bits: 31)
        mul32 = a.times_fraction(b, fraction_bits: 32)
        # The DSL divides only at sixteen bits and 32, so the other sizes are the step built by hand.
        div0 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 0))
        div1 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 1))
        div8 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 8))
        div31 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 31))
        i += 1
      end
    end
    run = PS1::CheckedRun.new.run(program, frames: PAIRS.length + 1)

    assert_operator run[:i], :>=, PAIRS.length, "every pair was worked out"
  end

  # A divide whose numerator passes 32 bits is worked out a digit of sixteen bits at a time, each digit
  # guessed and then taken down while it is too big. These pairs are drawn at every size, numerators and
  # divisors with every count of leading noughts, so the guesses come out right and too big alike.
  def test_quotients_of_wide_numerators_agree_with_the_interpreter_on_drawn_pairs
    random = Random.new(20_261_105)
    size = -> { random.rand(1..31).then { |bits| random.rand(1 << bits) * (random.rand(2).zero? ? 1 : -1) } }
    pairs = Array.new(300) { [size.call, size.call] }.reject { |_, b| b.zero? }
    program = program_of do
      screen :bitmap
      as = table :as, pairs.map(&:first), width: :word
      bs = table :bs, pairs.map(&:last), width: :word
      i = 0
      div16 = 0
      div26 = 0
      div31 = 0
      game_loop do
        a = as[i]
        b = bs[i]
        div16 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 16))
        div26 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 26))
        div31 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 31))
        i += 1
      end
    end
    run = PS1::CheckedRun.new.run(program, frames: pairs.length + 1)

    assert_operator run[:i], :>=, pairs.length, "every pair was worked out"
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end
end
