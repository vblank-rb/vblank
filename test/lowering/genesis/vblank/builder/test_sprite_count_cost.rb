# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# WHAT SPRITES NOT SHOWING COST ON THE GENESIS, measured in the emulator. A sprite not showing is
# a test of whether it shows (Lowering::Picture#emit_jump_unless_shown); the budget for one is a
# compare of a long word in memory with a number and a branch, under forty of the 68000's cycles
# (Motorola's 68000 instruction timing tables), so forty-four of them are under four of the
# frame's 262 lines, a line being about 480 cycles.
class TestGenesisSpriteCountCost < Minitest::Test
  LINES = 262
  BOUND_FORTY_FOUR = 4

  def test_forty_four_sprites_not_showing_cost_a_test_each
    share = SpriteCountCostGames.share_beyond(:genesis, SpriteCountCostGames.sprites_game(:genesis, 48),
                                              SpriteCountCostGames.sprites_game(:genesis, 4))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR, "forty-four sprites not showing cost #{(share * LINES).round(2)} lines"
  end

  def test_forty_four_empty_places_of_a_pool_cost_a_test_each
    share = SpriteCountCostGames.share_beyond(:genesis, SpriteCountCostGames.pool_game(:genesis, 48),
                                              SpriteCountCostGames.pool_game(:genesis, 4))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR, "forty-four empty places cost #{(share * LINES).round(2)} lines"
  end

  # IN A DRAW ORDER a thing not showing is left out of the sort and of the walk that places the
  # sprites (Lowering::ShownSort): it costs the test of whether it shows and one of whether it showed
  # last pass, a compare and a branch each, under eighty cycles, so forty-four are under eight lines.
  BOUND_FORTY_FOUR_ORDERED = 8

  def test_forty_four_sprites_not_showing_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:genesis, SpriteCountCostGames.sprites_game(:genesis, 48, ordered: true),
                                              SpriteCountCostGames.sprites_game(:genesis, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four sprites not showing cost #{(share * LINES).round(2)} lines"
  end

  def test_forty_four_empty_places_of_a_pool_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:genesis, SpriteCountCostGames.pool_game(:genesis, 48, ordered: true),
                                              SpriteCountCostGames.pool_game(:genesis, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four empty places cost #{(share * LINES).round(2)} lines"
  end
end
