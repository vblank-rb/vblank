# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# What sprites not showing cost in a draw order on the PlayStation, measured in the emulator. A thing
# not showing is left out of the sort and of the walk that places the sprites (Lowering::ShownSort):
# it costs the test of whether it shows and one of whether it showed last pass, a load, a compare and
# a branch each, so forty-four are under a line and a half of the frame's 263.
class TestPS1SpriteCountCost < Minitest::Test
  LINES = 263
  BOUND_FORTY_FOUR_ORDERED = 1.5

  def test_forty_four_sprites_not_showing_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:ps1, SpriteCountCostGames.sprites_game(:ps1, 48, ordered: true),
                                              SpriteCountCostGames.sprites_game(:ps1, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four sprites not showing cost #{(share * LINES).round(2)} lines"
  end

  def test_forty_four_empty_places_of_a_pool_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:ps1, SpriteCountCostGames.pool_game(:ps1, 48, ordered: true),
                                              SpriteCountCostGames.pool_game(:ps1, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four empty places cost #{(share * LINES).round(2)} lines"
  end
end
