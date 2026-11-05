# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"

# WHAT AN ORDER OF SEVEN COSTS ON THE GAME BOY COLOR, measured in the emulator. The sort is written
# in the Color's own code with both lists' places known, a compare an item when nobody passed
# anybody, so working out the seven numbers and sorting them is a few of the frame's 154 lines.
# Placing the sprites in a worked-out order costs the frame more than placing them where they were
# last frame, which is the rest of what the order costs.
class TestGBCDrawInOrderCost < Minitest::Test
  # The routine that works out the numbers and sorts them, as a share of the frame.
  private def sort_share
    DrawOrderCostGames.profile(:gbc, ordered: true).game.select { |row| row.routine.to_s.include?("__draw_order_1__sort") }
                      .sum(&:share)
  end

  def test_working_out_and_sorting_seven_takes_a_few_lines
    share = sort_share

    assert_operator share, :<, 0.06, "the sort takes #{(share * 154).round(1)} of the frame's 154 lines"
  end

  def test_an_order_of_seven_costs_under_an_eighth_of_the_frame
    share = DrawOrderCostGames.share_of_frame(:gbc)

    assert_operator share, :<, 0.125, "an order of seven costs #{(share * 100).round(1)}% of the frame"
  end
end
