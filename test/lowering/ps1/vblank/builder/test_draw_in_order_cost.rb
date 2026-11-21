# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# What a draw order's code costs on the PlayStation. The sort is written out a place at a time and
# run once a pass, so every byte of it is fetched from main RAM through the processor's 4 KB
# instruction cache on every pass (psx-spx, "Memory Map"): its bytes are its time as well as its
# room. A place is its number, its step of the sort, the test of whether it shows, and a call to the
# code every place shares that keeps its flag (Lowering::ShownSort): under 144 bytes, 36
# instructions. With the flag's work written out at every place it was more than 200.
class TestPS1DrawInOrderCost < Minitest::Test
  BYTES_A_PLACE = 144

  def test_each_place_of_a_pool_in_an_order_adds_under_a_hundred_and_forty_four_bytes
    bytes = SpriteCountCostGames.order_bytes_a_place(:ps1, :pool, 48)

    assert_operator bytes, :<, BYTES_A_PLACE, "each place of the pool added #{bytes.round(1)} bytes"
  end

  def test_each_sprite_in_an_order_adds_under_a_hundred_and_forty_four_bytes
    bytes = SpriteCountCostGames.order_bytes_a_place(:ps1, :sprites, 48)

    assert_operator bytes, :<, BYTES_A_PLACE, "each sprite added #{bytes.round(1)} bytes"
  end
end
