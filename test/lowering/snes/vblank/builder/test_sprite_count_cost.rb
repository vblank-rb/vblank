# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# WHAT SPRITES NOT SHOWING COST IN A DRAW ORDER ON THE SUPER NINTENDO, measured in the emulator. A
# thing not showing is left out of the sort and of the walk that places the sprites
# (Lowering::ShownSort): it costs the test of whether it shows and one of whether it showed last pass,
# a load and a branch each besides the test itself, so forty-four are under eight of the frame's 262
# lines, about twice what they cost outside an order.
class TestSNESSpriteCountCost < Minitest::Test
  LINES = 262
  BOUND_FORTY_FOUR_ORDERED = 8

  def test_forty_four_sprites_not_showing_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:snes, SpriteCountCostGames.sprites_game(:snes, 48, ordered: true),
                                              SpriteCountCostGames.sprites_game(:snes, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four sprites not showing cost #{(share * LINES).round(2)} lines"
  end

  def test_forty_four_empty_places_of_a_pool_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:snes, SpriteCountCostGames.pool_game(:snes, 48, ordered: true),
                                              SpriteCountCostGames.pool_game(:snes, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four empty places cost #{(share * LINES).round(2)} lines"
  end
end
