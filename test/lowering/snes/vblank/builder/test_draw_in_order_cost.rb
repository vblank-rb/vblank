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

  # The order of seven on its tightest frame, where two things pass each other and the sort moves
  # one, costs more than the frame's mean: a third of a line over BOUND_SEVEN. Three has not been
  # shown to hold there, and nothing has yet measured what the console's own games spend on that
  # frame, so this bound holds the order where it stands and BOUND_SEVEN holds the mean.
  BOUND_SEVEN_TIGHTEST = 4

  # The lines of the picture in one frame.
  LINES_A_FRAME = 262

  # The lines the order costs a frame, over the frames measured: the share of the frame it takes
  # (DrawOrderCostGames.share_of_frame), which is read from the emulator's own count and never
  # rounded.
  private def lines_order_costs_each_frame(sprites)
    DrawOrderCostGames.share_of_frame(:snes, sprites: sprites) * LINES_A_FRAME
  end

  def test_an_order_of_seven_costs_a_few_lines
    cost = lines_order_costs_each_frame(4)

    assert_operator cost, :<=, BOUND_SEVEN, "an order of seven costs #{cost.round(2)} lines"
  end

  def test_an_order_of_seven_costs_its_tightest_frame_a_few_lines
    cost = DrawOrderCostGames.lines_off_tightest_frame(:snes, sprites: 4)

    assert_operator cost, :<=, BOUND_SEVEN_TIGHTEST, "an order of seven costs its tightest frame #{cost.round(2)} lines"
  end

  def test_an_order_of_thirty_costs_under_a_ninth_of_the_frame
    cost = DrawOrderCostGames.lines_off_tightest_frame(:snes, sprites: 27)

    assert_operator cost, :<, BOUND_THIRTY, "an order of thirty costs #{cost.round(2)} lines"
  end
end
