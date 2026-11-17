# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"
require "sprite_count_cost_games"

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

  # A THING NOT SHOWING is left out of the sort and of the run's copy into the sprite table
  # (ShownSort): it costs the test of whether it shows and one of whether it showed last pass, a
  # handful of instructions each, so forty-four cost under a line and a half of the frame's 228.
  LINES = 228
  BOUND_FORTY_FOUR = 1.5

  def test_forty_four_sprites_not_showing_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:gba, SpriteCountCostGames.sprites_game(:gba, 48, ordered: true),
                                              SpriteCountCostGames.sprites_game(:gba, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR, "forty-four sprites not showing cost #{(share * LINES).round(2)} lines"
  end

  def test_forty_four_empty_places_of_a_pool_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:gba, SpriteCountCostGames.pool_game(:gba, 48, ordered: true),
                                              SpriteCountCostGames.pool_game(:gba, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR, "forty-four empty places cost #{(share * LINES).round(2)} lines"
  end
end
