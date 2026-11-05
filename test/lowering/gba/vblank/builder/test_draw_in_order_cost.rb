# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"

# WHAT AN ORDER COSTS ON THE ADVANCE, measured in the emulator. The sort is written in the
# cartridge's own code beside the order's numbers, about twenty instructions a thing on a frame
# where nobody passed anybody, so seven things cost a sliver of the frame and thirty a little more
# than four times that.
class TestGBADrawInOrderCost < Minitest::Test
  def test_an_order_of_seven_costs_a_sliver_of_the_frame
    share = DrawOrderCostGames.share_of_frame(:gba)

    assert_operator share, :<, 0.003, "an order of seven costs #{(share * 100).round(2)}% of the frame"
  end

  def test_an_order_of_thirty_costs_under_a_sixtieth_of_the_frame
    share = DrawOrderCostGames.share_of_frame(:gba, sprites: 27)

    assert_operator share, :<, 1 / 60.0, "an order of thirty costs #{(share * 100).round(2)}% of the frame"
  end
end
