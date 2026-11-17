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

  # AND A PLACE THAT CAN HIDE IS WRITTEN SHORT. The sort is a routine that runs every frame, so the
  # build puts it in the console's quick memory if it fits (GBA::Placement), beside every other
  # routine that wants a place there: bytes it takes are bytes another routine cannot have, and a
  # sort grown by a few kilobytes pushes out something else that runs every frame. A place costs its
  # test, its number, and a call to the code all places share that keeps its flag (ShownSort):
  # about fifteen instructions. The same code written out at every place was more than thirty, and
  # a game with a few dozen places in an order lost routines from the quick memory to it.
  BYTES_A_PLACE = 64

  def test_each_place_of_a_pool_in_an_order_adds_under_sixty_four_bytes_to_its_sort
    bytes = SpriteCountCostGames.order_sort_bytes(:gba, SpriteCountCostGames.pool_game(:gba, 48, ordered: true)) -
            SpriteCountCostGames.order_sort_bytes(:gba, SpriteCountCostGames.pool_game(:gba, 4, ordered: true))

    assert_operator bytes / 44.0, :<, BYTES_A_PLACE, "each place of the pool added #{(bytes / 44.0).round(1)} bytes to the sort"
  end

  def test_each_sprite_in_an_order_adds_under_sixty_four_bytes_to_its_sort
    bytes = SpriteCountCostGames.order_sort_bytes(:gba, SpriteCountCostGames.sprites_game(:gba, 48, ordered: true)) -
            SpriteCountCostGames.order_sort_bytes(:gba, SpriteCountCostGames.sprites_game(:gba, 4, ordered: true))

    assert_operator bytes / 44.0, :<, BYTES_A_PLACE, "each sprite added #{(bytes / 44.0).round(1)} bytes to the sort"
  end
end
