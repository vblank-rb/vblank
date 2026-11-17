# frozen_string_literal: true

require "test_helper"
require "number_width_cost_games"

# A TEST OF NUMBERS PROVEN SMALL ON THE GAME BOY COLOR, measured in the emulator: two sides that stay
# in a byte compared with one CP, with their sign bits turned over where they can be below nought, and
# two that stay in 16 bits with a two-byte subtraction (GBC::Lowering::SmallNumbers), where a
# comparison of two whole numbers calls rt_cmp32; a size or a shift down of such a number worked in its
# two bytes (WrittenNumbers#low_value). The console's own games compare a byte with one `cp`, two
# machine cycles (Pan Docs, "CPU Instruction Set").
class TestGBCNumberWidthCost < Minitest::Test
  # A frame's cycles at double speed: 154 lines of 912.
  FRAME_CYCLES = 140_448

  # Measured, cycles a test, with every number worked in four bytes and then with the numbers proven
  # small worked in one or two: how far apart two byte slots are, 740 then 448; a variable against a
  # number, 102 then 74; a half slot shifted down by 4, 408 then 180; a table of bytes against a
  # variable, 613 then 283.
  BOUNDS = { pair: 480, number: 80, shift: 195, table: 300 }.freeze

  BOUNDS.each do |shape, bound|
    define_method(:"test_a_#{shape}_test_costs_under_#{bound}_cycles") do
      cost = NumberWidthCostGames.cycles_a_test(:gbc, shape, FRAME_CYCLES)

      assert_operator cost, :<, bound, "a #{shape} test costs #{cost.round(1)} cycles"
    end
  end

  # The tests are the interpreter's on every pass.
  def test_the_tests_are_the_interpreters_on_every_pass
    NumberWidthCostGames::TESTS_A_PASS.each_key do |shape|
      game_player.run(NumberWidthCostGames.game(:gbc, shape).program(console: :gbc), frames: 40)
    end
  end
end
