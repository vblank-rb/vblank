# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"

# WHAT AN ORDER COSTS ON THE SUPER NINTENDO, measured in the emulator: the fewest lines any frame
# has to spare, without the order and with it. The console's own games sort every sprite on the
# screen by height each frame, about ten instructions a sprite, so an order of seven must cost a few of the
# frame's 262 lines, not the thirty it cost written as list reads and writes, and an order of
# thirty must leave most of the frame to the game. The fewest lines is a frame where two things
# pass each other, so a move is in the cost.
class TestSNESDrawInOrderCost < Minitest::Test
  private def lines_lost(sprites)
    without = DrawOrderCostGames.profile(:snes, ordered: false, sprites: sprites).fewest_lines_spare
    with = DrawOrderCostGames.profile(:snes, ordered: true, sprites: sprites).fewest_lines_spare
    without - with
  end

  def test_an_order_of_seven_costs_a_few_lines
    cost = lines_lost(4)

    assert_operator cost, :<=, 3, "an order of seven costs #{cost} lines"
  end

  def test_an_order_of_thirty_costs_under_a_ninth_of_the_frame
    cost = lines_lost(27)

    assert_operator cost, :<, 28, "an order of thirty costs #{cost} lines"
  end
end
