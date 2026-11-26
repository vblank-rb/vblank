# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# What sprites not showing cost on the Super Nintendo, measured in the emulator. In a draw order, a
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

  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = LINES * 1364

  # Sprites a scene owns cost a scene that is up one test for all of them, nothing a sprite: the
  # scene's test is asked once for its run of sprites (Backends::ShownWhen.scene_runs), as a console's
  # own games walk a list of the objects they have made rather than every object they could make.
  # Four sprites of a scene not up cost the test of the scene, a load, a compare and a branch, about a
  # sixth of what four cost while each asked its own product. Past a few sprites the jump over them is
  # a long one, a few cycles more, and sixteen more beyond that cost nothing.
  BOUND_FOUR_IN_ANOTHER_SCENE = 160
  BOUND_SIXTEEN_MORE_IN_ANOTHER_SCENE = 24

  def test_four_sprites_of_a_scene_not_up_cost_one_test
    clocks = scene_clocks_beyond(4, 0)

    assert_operator clocks, :<, BOUND_FOUR_IN_ANOTHER_SCENE, "four sprites in another scene cost #{clocks.round} master clocks"
  end

  def test_more_sprites_of_a_scene_not_up_cost_nothing_more
    clocks = scene_clocks_beyond(32, 16)

    assert_operator clocks, :<, BOUND_SIXTEEN_MORE_IN_ANOTHER_SCENE, "sixteen more sprites in another scene cost #{clocks.round} master clocks"
  end

  def test_forty_four_empty_places_of_a_pool_in_an_order_cost_two_tests_each
    share = SpriteCountCostGames.share_beyond(:snes, SpriteCountCostGames.pool_game(:snes, 48, ordered: true),
                                              SpriteCountCostGames.pool_game(:snes, 4, ordered: true))

    assert_operator share * LINES, :<, BOUND_FORTY_FOUR_ORDERED, "forty-four empty places cost #{(share * LINES).round(2)} lines"
  end

  private def scene_clocks_beyond(owned, fewer)
    SpriteCountCostGames.share_beyond(:snes, SpriteCountCostGames.scene_game(:snes, owned),
                                      SpriteCountCostGames.scene_game(:snes, fewer)) * FRAME_CLOCKS
  end
end
