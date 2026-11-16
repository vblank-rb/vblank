# frozen_string_literal: true

require "test_helper"

# THE WAYS A SUPER NINTENDO CARTRIDGE WORKS A SUM OUT IN PLACE when one of its numbers is written in
# the program — a product by a written number (Lowering#emit_product_by_written_number) or by a
# comparison (#emit_product_by_comparison), a shift
# right read from where the number is kept (#emit_shift_right_from_place), two shifts right taken as
# one, a byte or half slot of a list said equal to a written number (#compare_narrow_slot), a repeat
# of a written count, and how many a list holds — give what the interpreter gives for every number,
# below nought and past every edge included. Every answer is checked against the interpreter's on
# every pass.
class TestSNESWrittenNumberPaths < Minitest::Test
  # Each number a quick way can get wrong: either side of nought, of a byte, of a half and of the
  # top byte's sign, a number whose low bytes are nought but whose upper bytes are not, and the two
  # ends of a number, which a product wraps past.
  EDGES = [0, 1, -1, 2, 3, 5, -7, 127, 128, -128, -129, 255, 256, -256, 300, 0x7FFF, 0x8000, -0x8000,
           -0x8001, 0xFFFF, 0x1_0000, -0x1_0000, 0x7F_FFFF, 0x80_0000, -0x80_0000, 16_843_009,
           0x7FFF_FFFF, -0x8000_0000, -0x7FFF_FFFF].freeze

  # Products by written numbers: small ones the multiplier takes, the largest it takes, ones below
  # nought, and powers of two of every byte count.
  FACTORS = [3, 6, 7, 10, 100, 255, -3, -255, 4, 256, 1024, 65_536, 1 << 24, -16, 0, 1, -1].freeze

  # Shifts right of a variable, and of a word slot of a list, by each count a byte or more.
  COUNTS = [8, 9, 12, 15, 16, 17, 23, 24, 25, 30, 31].freeze

  # Numbers a byte slot and a half slot are said equal to: each fits the slot's width.
  BYTE_TESTS = [0, 1, -1, 5, 127, -128].freeze
  HALF_TESTS = [0, -1, 300, 0x7FFF, -0x8000].freeze

  # A comparison's answer (1 or 0) tested against 1 or 0, as a pool's drawing tests whether a slot
  # is live (Lowering#comparison_in_truth_test): each way round, of each comparison.
  TRUTH_TESTS = [[:==, 1], [:!=, 0], [:==, 0], [:!=, 1]].freeze
  COMPARED = [[:<, 5], [:>=, -128], [:==, 3], [:>, 300]].freeze

  Build = VBlank::IR::Build

  # Each of EDGES in turn, one a pass, and every answer above for it kept in a variable of its own.
  def self.game_of_edges
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      edges = table :edges, TestSNESWrittenNumberPaths::EDGES, width: :word
      at = var :at, 0
      n = var :n, 0
      kept = ->(what, list) { list.each_index.map { |i| var :"#{what}#{i}", 0 } }
      products = kept.call(:product, TestSNESWrittenNumberPaths::FACTORS)
      shifted = kept.call(:shifted, TestSNESWrittenNumberPaths::COUNTS)
      slot_shifted = kept.call(:slot_shifted, TestSNESWrittenNumberPaths::COUNTS)
      bytes_equal = kept.call(:byte_equal, TestSNESWrittenNumberPaths::BYTE_TESTS)
      halves_equal = kept.call(:half_equal, TestSNESWrittenNumberPaths::HALF_TESTS)
      twice = var :twice, 0
      counted = var :counted, 0
      held = var :held, 0
      words = list :words, capacity: 2, full_of: 0
      narrow = list :narrow, capacity: 2, width: :byte, full_of: 0
      halves = list :halves, capacity: 2, width: :half, full_of: 0
      growing = list :growing, capacity: 2
      truths = TestSNESWrittenNumberPaths::TRUTH_TESTS.each_index.flat_map do |i|
        TestSNESWrittenNumberPaths::COMPARED.each_index.map do |j|
          var(:"truth#{i}_#{j}", 0)
          :"truth#{i}_#{j}"
        end
      end
      TestSNESWrittenNumberPaths::COMPARED.each_index do |j|
        var :"gated#{j}", 0
        var :"gated_left#{j}", 0
        var :"gated_slot#{j}", 0
      end
      game_loop do
        n.store!(edges[at])
        TestSNESWrittenNumberPaths::FACTORS.each_with_index { |factor, i| products[i].store!(n * factor) }
        TestSNESWrittenNumberPaths::COUNTS.each_with_index { |count, i| shifted[i].store!(n >> count) }
        twice.store!((n >> 8) >> 4)
        words[1] = n
        narrow[1] = n
        halves[1] = n
        TestSNESWrittenNumberPaths::COUNTS.each_with_index { |count, i| slot_shifted[i].store!(words[1] >> count) }
        TestSNESWrittenNumberPaths::BYTE_TESTS.each_with_index do |number, i|
          bytes_equal[i].store!(0)
          bytes_equal[i].store!(1) if narrow[1] == number
        end
        TestSNESWrittenNumberPaths::HALF_TESTS.each_with_index do |number, i|
          halves_equal[i].store!(1)
          halves_equal[i].store!(0) if halves[1] != number
        end
        growing.push n
        held.store!(growing.length)
        growing.pop
        counted.store!(0)
        repeat(3) { counted.increase!(1) }
        ir = TestSNESWrittenNumberPaths::Build
        truths.each_with_index do |truth, k|
          (op, said), (comparison, bound) = TestSNESWrittenNumberPaths::TRUTH_TESTS.product(TestSNESWrittenNumberPaths::COMPARED)[k]
          compared = ir.binop(comparison, ir.var_ref(:n), ir.int(bound))
          record(ir.set(truth, ir.int(0)))
          record(ir.if_(ir.binop(op, compared, ir.int(said)), ir.set(truth, ir.int(1))))
        end
        # A product by a comparison (Lowering#emit_product_by_comparison), the comparison on
        # either side; and one by a list's item, which could stop the game and so is multiplied.
        TestSNESWrittenNumberPaths::COMPARED.each_with_index do |(comparison, bound), j|
          compared = -> { ir.binop(comparison, ir.var_ref(:n), ir.int(bound)) }
          record(ir.set(:"gated#{j}", ir.binop(:*, ir.var_ref(:n), compared.call)))
          record(ir.set(:"gated_left#{j}", ir.binop(:*, compared.call, ir.binop(:+, ir.var_ref(:n), ir.int(7)))))
          record(ir.set(:"gated_slot#{j}", ir.binop(:*, compared.call, ir.list_get(:words, ir.int(1)))))
        end
        TestSNESWrittenNumberPaths.narrow_sums(self, n, narrow, halves)
        at.increase!(1)
      end
    end
    b.finalize_program
    b.program
  end

  # SUMS INTO A BYTE OR HALF SLOT, worked out in their low half (Lowering#slot_value): of slots at a
  # written index and at a variable's, of variables and written numbers, a side that is a sum of its
  # own, a byte slot read into a half, and each operator. Each slot written is read back into a
  # variable of its own at once, so every answer is held to the interpreter's.
  def self.narrow_sums(builder, n, narrow, halves)
    builder.instance_eval do
      one = var :one, 1
      sums = [
        [narrow, 0, -> { narrow[1] + 1 }],
        [narrow, 0, -> { narrow[one] - n }],
        [narrow, 0, -> { n - (narrow[one] + 3) }],
        [narrow, 0, -> { (narrow[one] | 5) ^ halves[one] }],
        [narrow, 0, -> { (narrow[1] + 1) & 3 }],
        [halves, 0, -> { halves[1] + 0x7FFF }],
        [halves, 0, -> { narrow[1] - halves[1] }],
        [halves, 0, -> { narrow[one] + narrow[one] }],
        [halves, 0, -> { (halves[one] ^ n) & 0x7F0F }],
        [halves, 0, -> { 1000 - (halves[one] - (narrow[one] + n)) }],
        [halves, one, -> { narrow[1] }]
      ]
      sums.each_with_index do |(list, index, sum), i|
        list[index] = sum.call
        var(:"narrow_sum#{i}", 0).store!(list[index])
      end
      halves[one] = n
    end
  end

  def test_every_answer_is_the_interpreters_at_each_edge
    game_player.run(self.class.game_of_edges, frames: EDGES.size + 2)
  end

  # Enough variables that the least used go past the first 8K of work RAM, to a long address. A
  # half written as nought goes straight into the variable, and the 65816 has no STZ to a long
  # address, so it must go through A there.
  def self.game_of_far_halves
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      many = Array.new(1900) { |i| var :"many#{i}", i }
      n = var :n, 0x1234_5678
      low = var :low, 0
      high = var :high, 0
      total = var :total, 0
      func(:touch_every_one) { many.each { |each_one| total.increase!(each_one) } }
      game_loop do
        low.store!(n & 0xFF)
        high.store!(n & -0x1_0000)
        n.increase!(0x1_0001)
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_nought_half_into_a_far_variable_is_the_interpreters
    game_player.run(self.class.game_of_far_halves, frames: 4)
  end
end
