# frozen_string_literal: true

require "test_helper"
require "stringio"

# A TABLE LONGER THAN 256 ENTRIES READ AT AN INDEX THE GAME WORKS OUT, on the Color. The read holds
# the index between the table's ends (IR::Build#table_read), and an index in range — almost every
# one — must be found so on the two bytes that can hold it, as the console's own games read such a
# table with a 16-bit add and a load, rather than by the runtime's 32-bit clamp and its two 32-bit
# compares (Lowering#value_of_clamped); and one outside is made the nearer end without them.
class TestGBCLongTableCost < Minitest::Test
  READS_A_PASS = 8

  # A game reading a 300-entry table READS_A_PASS times a pass, at indexes it works out from a
  # number nothing proves anything of as it builds (it turns round and stays nought): most in
  # range, and one each below nought, past the end, and past two bytes.
  private def long_reads
    VBlank.game("LONG READS", consoles: %i[gbc]) do
      long = table :long, Array.new(300) { |i| (i * 7) % 1000 }, width: :half
      wobble = var :wobble, 0
      sum = var :sum, 0
      game_loop do
        sum.store!(0)
        [0, 150, 256, 299, 260, -5, 400, 70_000].each { |at| sum += long[wobble + at] }
        wobble = 0 - wobble
      end
    end
  end

  private def profile(game)
    game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false).profile(out: StringIO.new, frames: 30)
  end

  def test_an_index_in_range_or_out_is_held_without_a_32_bit_compare
    spent = profile(long_reads).runtime.to_h { |row| [row.routine, row.share] }

    %w[rt_clamp32 rt_cmp32].each do |routine|
      assert_equal 0, spent.fetch(routine, 0), "#{routine} takes #{(spent[routine].to_f * 100).round(2)}% of the frame"
    end
  end

  def test_every_read_is_the_interpreters
    game_player.run(long_reads.program(console: :gbc), frames: 4)
  end
end
