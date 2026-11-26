# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# What sprites not showing cost on the Genesis, measured in the emulator. A sprite not showing is
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

  # In a draw order a thing not showing is left out of the sort and of the walk that places the
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

  # A frame's 68000 cycles: 262 lines of about 488.
  FRAME_CYCLES = LINES * 488

  # Sprites a scene owns cost a scene that is up one test for all of them, nothing a sprite: the
  # scene's test is asked once for its run of sprites (Backends::ShownWhen.scene_runs), as a console's
  # own games walk a list of the objects they have made rather than every object they could make.
  # Four sprites of a scene not up cost the test of the scene, a compare of a long word and a branch,
  # where each asked its own before; sixteen more cost nothing.
  BOUND_FOUR_IN_ANOTHER_SCENE = 60
  BOUND_SIXTEEN_MORE_IN_ANOTHER_SCENE = 10

  def test_four_sprites_of_a_scene_not_up_cost_one_test
    cycles = scene_cycles_beyond(4, 0)

    assert_operator cycles, :<, BOUND_FOUR_IN_ANOTHER_SCENE, "four sprites in another scene cost #{cycles.round} cycles"
  end

  def test_more_sprites_of_a_scene_not_up_cost_nothing_more
    cycles = scene_cycles_beyond(32, 16)

    assert_operator cycles, :<, BOUND_SIXTEEN_MORE_IN_ANOTHER_SCENE, "sixteen more sprites in another scene cost #{cycles.round} cycles"
  end

  private def scene_cycles_beyond(owned, fewer)
    SpriteCountCostGames.share_beyond(:genesis, SpriteCountCostGames.scene_game(:genesis, owned),
                                      SpriteCountCostGames.scene_game(:genesis, fewer)) * FRAME_CYCLES
  end
end
