# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"

# WHAT AN ORDER COSTS ON THE SUPER NINTENDO, measured in the emulator. The console's own games sort
# every sprite on the screen by height each frame, about ten instructions a sprite, so an order of
# seven must cost a few of the frame's 262 lines, not the thirty it cost written as list reads and
# writes, and an order of thirty must leave most of the frame to the game.
class TestSNESDrawInOrderCost < Minitest::Test
  BOUND_SEVEN = 3
  BOUND_THIRTY = 28

  # The lines of the picture in one frame.
  LINES_A_FRAME = 262

  # The lines the order costs a frame, over the frames measured: the share of the frame it takes
  # (DrawOrderCostGames.share_of_frame), which is read from the emulator's own count and never
  # rounded.
  private def lines_order_costs_each_frame(sprites)
    DrawOrderCostGames.share_of_frame(:snes, sprites: sprites) * LINES_A_FRAME
  end

  # The lines the order costs the tightest frame, one where two things pass each other, so a move
  # is in the cost: the whole lines that frame has to spare without the order, less those with it.
  # Each of the two is rounded down to a line, so this reads a line over or under what the order
  # costs, and the same order can read a line more when the game without it gets faster. Only a
  # bound with more than a line of room is held to it.
  private def lines_order_costs_tightest_frame(sprites)
    spare = ->(ordered) { DrawOrderCostGames.profile(:snes, ordered: ordered, sprites: sprites).fewest_lines_spare }
    spare.call(false) - spare.call(true)
  end

  def test_an_order_of_seven_costs_a_few_lines
    cost = lines_order_costs_each_frame(4)

    assert_operator cost, :<=, BOUND_SEVEN, "an order of seven costs #{cost.round(2)} lines"
  end

  def test_an_order_of_thirty_costs_under_a_ninth_of_the_frame
    cost = lines_order_costs_tightest_frame(27)

    assert_operator cost, :<, BOUND_THIRTY, "an order of thirty costs #{cost} lines"
  end
end
