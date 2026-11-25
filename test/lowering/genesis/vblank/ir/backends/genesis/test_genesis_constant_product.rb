# frozen_string_literal: true

require "test_helper"
require "stringio"

# Multiplying by a number written in the game on the Genesis: shifts, adds and subtracts, or two of the
# 68000's word multiplies, written where the sum is (Lowering::Products), and a product by a comparison
# as a branch; never the runtime's multiply, which takes three word multiplies and a call. The answers
# are held to the interpreter's for every number past every edge, on every pass; the shortcut is read
# from where Genesis Plus GX says the time went.
class TestGenesisConstantProduct < Minitest::Test
  # Each number a quick way can get wrong: either side of nought, of a byte, of a half and of the top
  # bit, and the two ends of a number, which a product wraps past.
  EDGES = [0, 1, -1, 2, 3, 7, -7, 127, 128, -128, 255, 256, 300, 0x7FFF, 0x8000, -0x8000, 0xFFFF, 0x1_0000,
           -0x1_0000, 0x1234_5678, 0x7FFF_FFFF, -0x8000_0000, -0x7FFF_FFFF].freeze

  # Products by written numbers: powers of two each side of sixteen places, runs of set bits, numbers
  # of up to sixteen bits that two word multiplies take, numbers past sixteen bits, numbers below
  # nought, the lowest number, and nought and one.
  FACTORS = [3, 10, 40, 255, 320, 1000, 0x7FFF, 0xFFFF, 0xAAAA, 0x1_0001, 0x10_0000, 0x7FFF_FFFF, 1_664_525, 1_103_515_245,
             -1, -3, -12, -1000, -0x8000_0000, 1 << 17, 0, 1].freeze

  # Comparisons a product is gated by, each way round.
  COMPARED = [[:<, 5], [:>=, -128], [:==, 3], [:!=, 0]].freeze

  Build = VBlank::IR::Build

  # Each of EDGES in turn, one a pass, and every product of it kept in a variable of its own.
  def self.game_of_edges
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :genesis))
    b.instance_eval do
      edges = table :edges, TestGenesisConstantProduct::EDGES, width: :word
      at = var :at, 0
      n = var :n, 0
      FACTORS.each_index { |i| var :"product#{i}", 0 }
      COMPARED.each_index do |j|
        var :"gated#{j}", 0
        var :"gated_left#{j}", 0
      end
      ir = TestGenesisConstantProduct::Build
      game_loop do
        n.store!(edges[at])
        TestGenesisConstantProduct::FACTORS.each_with_index do |factor, i|
          record(ir.set(:"product#{i}", i.even? ? ir.binop(:*, ir.var_ref(:n), ir.int(factor)) : ir.binop(:*, ir.int(factor), ir.var_ref(:n))))
        end
        TestGenesisConstantProduct::COMPARED.each_with_index do |(comparison, bound), j|
          compared = -> { ir.binop(comparison, ir.var_ref(:n), ir.int(bound)) }
          record(ir.set(:"gated#{j}", ir.binop(:*, ir.var_ref(:n), compared.call)))
          record(ir.set(:"gated_left#{j}", ir.binop(:*, compared.call, ir.binop(:+, ir.var_ref(:n), ir.int(7)))))
        end
        at.increase!(1)
      end
    end
    b.finalize_program
    b.program
  end

  def test_every_product_is_the_interpreters_at_each_edge
    game_player.run(self.class.game_of_edges, frames: EDGES.size + 2)
  end

  # A pass of +turns+ products of a number the game changes each pass, by +factor+ (:worked_out for a
  # number the game works out).
  def self.products_game(factor, turns: 60)
    VBlank.game("PRODUCTS", consoles: %i[genesis]) do
      n = var :n, 3
      by = var :by, 1000
      total = var :total, 0
      game_loop do
        n.increase!(1)
        repeat(turns) do
          total.store!(total + (factor == :worked_out ? n * by : n * factor))
        end
      end
    end
  end

  MULTIPLY = /\Art_mul32/

  private def multiply_share(factor)
    rom = self.class.products_game(factor).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, settle: 2, frames: 4).runtime.select { |spent| spent.routine.to_s.match?(MULTIPLY) }.sum(&:share)
  end

  # The random draw's own multiplier among them, 21 bits wide.
  def test_a_written_number_never_reaches_the_multiply_routine
    [1000, 0xAAAA, 0x1_0001, -12, VBlank::Builder::Randomness::RNG_MULT].each do |factor|
      assert_equal 0, multiply_share(factor), "a product by #{factor}"
    end
  end

  # ...where a number the game works out does, so the profile would have shown it.
  def test_a_worked_out_number_still_multiplies
    assert_operator multiply_share(:worked_out), :>, 0
  end
end
