# frozen_string_literal: true

require "test_helper"

# Numbers that hold a fraction (`times_fraction`, and `/` of two fractions), worked out by 68000 code on 64
# bits: each pass multiplies and divides a pair of numbers read from a table at several fraction sizes, and
# the interpreter does the same, so one number out by one anywhere fails the pass it first differs on. The
# pairs are the awkward ones: both signs, the lowest and highest numbers, nought, and products and quotients
# too big for 32 bits.
class TestGenesisFractions < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  EDGES = [0, 1, -1, 3, -3, 65_536, -65_536, 98_304, -98_304, 123_456_789, -123_456_789, 0x7FFFFFFF,
           -0x80000000, 0x40000000, -0x40000000, 255, -255, 46_341, 65_535].freeze
  PAIRS = EDGES.product(EDGES).freeze

  def test_products_and_quotients_of_fractions_agree_with_the_interpreter_on_the_awkward_pairs
    firsts = PAIRS.map(&:first)
    seconds = PAIRS.map(&:last)
    program = program_of do
      screen :bitmap
      as = table :as, firsts, width: :word
      bs = table :bs, seconds, width: :word
      i = 0
      mul0 = 0
      mul8 = 0
      mul16 = 0
      mul31 = 0
      div0 = 0
      div8 = 0
      div16 = 0
      div31 = 0
      game_loop do
        a = as[i]
        b = bs[i]
        mul0 = a.times_fraction(b, fraction_bits: 0)
        mul8 = a.times_fraction(b, fraction_bits: 8)
        mul16 = a.times_fraction(b, fraction_bits: 16)
        mul31 = a.times_fraction(b, fraction_bits: 31)
        div0 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 0))
        div8 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 8))
        div16 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 16))
        div31 = VBlank::DSL::Value.new(self, VBlank::IR::Build.div_fix(a.node, b.node, 31))
        i += 1
      end
    end
    run = Genesis::CheckedRun.new.run(program, frames: PAIRS.length + 1)

    assert_operator run[:i], :>=, PAIRS.length, "every pair was worked out"
  end

  def test_a_game_that_walks_a_speed_with_a_fraction_agrees_pass_for_pass
    program = program_of do
      screen :bitmap
      x = 0
      speed = 98_304 # 1.5 pixels a pass, with 16 bits of fraction
      gravity = 3_277 # a twentieth
      game_loop do
        speed = speed - gravity
        x = x + speed.times_fraction(55_705, fraction_bits: 16)
      end
    end
    run = Genesis::CheckedRun.new.run(program, frames: 60)

    refute_equal 0, run[:x]
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end
end
