# frozen_string_literal: true

require "test_helper"
require "number_width_cost_games"

# A TEST OF NUMBERS PROVEN SMALL ON THE SUPER NINTENDO, measured in the emulator: two sides that stay
# in 16 bits (Backends::NumberRanges) compared with one CMP, or a subtract whose sign is turned back
# where it overflowed, of their low halves alone (SNES::Lowering#compare_within_halves); a slot of
# bytes read with its sign carried into the high byte, a size or a shift down worked in the 16-bit
# accumulator (#emit_low_half_of_narrow_step). The console's own games keep such numbers in 8 or 16
# bits and test them that way (65816 instruction timings: fullsnes, "CPU 65XX Microprocessor").
class TestSNESNumberWidthCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Measured, master clocks a test, with both halves of every number worked out and then with the
  # numbers proven small worked in 16 bits: how far apart two byte slots are, 1474 then 612; a
  # variable against a number, 105 then 65; a half slot shifted down by 4, 780 then 158; a table of
  # bytes against a variable, 813 then 250.
  BOUNDS = { pair: 650, number: 75, shift: 175, table: 270 }.freeze

  BOUNDS.each do |shape, bound|
    define_method(:"test_a_#{shape}_test_costs_under_#{bound}_master_clocks") do
      cost = NumberWidthCostGames.cycles_a_test(:snes, shape, FRAME_CLOCKS)

      assert_operator cost, :<, bound, "a #{shape} test costs #{cost.round(1)} master clocks"
    end
  end

  # The tests are the interpreter's on every pass.
  def test_the_tests_are_the_interpreters_on_every_pass
    NumberWidthCostGames::TESTS_A_PASS.each_key do |shape|
      game_player.run(NumberWidthCostGames.game(:snes, shape).program(console: :snes), frames: 40)
    end
  end
end
