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

  # A frame's processor cycles: 33.8688 MHz over sixty frames a second.
  FRAME_CYCLES = 33_868_800 / 60

  # Sprites a scene owns cost a scene that is up one test for all of them, nothing a sprite: the
  # scene's test is asked once for its run of sprites (Backends::ShownWhen.scene_runs), as a console's
  # own games walk a list of the objects they have made rather than every object they could make.
  # The game loop's own share is measured: the processor also waits for the graphics chip, and that
  # wait moves by a few lines as the code grows, whatever the code does. Four sprites of a scene not
  # up cost the test of the scene, a load, a compare and a branch, where each worked out its own
  # product before; sixteen more cost nothing.
  BOUND_FOUR_IN_ANOTHER_SCENE = 100
  BOUND_SIXTEEN_MORE_IN_ANOTHER_SCENE = 40

  def test_four_sprites_of_a_scene_not_up_cost_one_test
    cycles = scene_cycles_beyond(4, 0)

    assert_operator cycles, :<, BOUND_FOUR_IN_ANOTHER_SCENE, "four sprites in another scene cost the game loop #{cycles.round} cycles"
  end

  def test_more_sprites_of_a_scene_not_up_cost_nothing_more
    cycles = scene_cycles_beyond(32, 16)

    assert_operator cycles, :<, BOUND_SIXTEEN_MORE_IN_ANOTHER_SCENE, "sixteen more sprites in another scene cost the game loop #{cycles.round} cycles"
  end

  private def scene_cycles_beyond(owned, fewer)
    SpriteCountCostGames.game_loop_share_beyond(:ps1, SpriteCountCostGames.scene_game(:ps1, owned),
                                                SpriteCountCostGames.scene_game(:ps1, fewer)) * FRAME_CYCLES
  end
end
