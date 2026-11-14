# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"

# WHAT AN ORDER OF SEVEN COSTS ON THE GAME BOY COLOR, measured in the emulator. The sort is written
# in the Color's own code with both lists' places known, a compare an item when nobody passed
# anybody, so working out the seven numbers and sorting them is a few of the frame's 154 lines.
# Placing the sprites in a worked-out order costs little more than placing them in a fixed one: a
# sprite whose place in the order held is left as it is in the sprite table, as the frame's other
# sprites are, and each place in the order is one byte read. So the whole order is the sort and
# a line or two.
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

  def test_an_order_of_seven_costs_under_ten_lines
    share = DrawOrderCostGames.share_of_frame(:gbc)

    assert_operator share, :<, 0.06, "an order of seven costs #{(share * 154).round(1)} of the frame's 154 lines"
  end
end
