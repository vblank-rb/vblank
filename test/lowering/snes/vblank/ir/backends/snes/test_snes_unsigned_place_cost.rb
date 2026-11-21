# frozen_string_literal: true

require "test_helper"
require "unsigned_place_cost_games"

# A pool's places in 256THS OF A PIXEL ON THE SUPER NINTENDO, measured in the emulator: places from
# 0 to 65535 kept with `& 0xFFFF`, which no signed slot holds, kept in half words read back with no
# sign (SNES::Lowering#unsigned_list?) and compared with one CMP of their 16 bits
# (SNES::Lowering#compare_within_halves). The console's own games keep such a place in one word.
class TestSNESUnsignedPlaceCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Measured: a thing's step was 1146 master clocks with its places in whole words, and 860 in half
  # words read with no sign.
  def test_a_things_step_costs_under_900_master_clocks
    cost = UnsignedPlaceCostGames.cycles_a_thing(:snes, FRAME_CLOCKS)

    assert_operator cost, :<, 900, "a thing costs #{cost.round(1)} master clocks"
  end

  # The places are the interpreter's on every pass.
  def test_the_places_are_the_interpreters_on_every_pass
    game_player.run(UnsignedPlaceCostGames.game(:snes, UnsignedPlaceCostGames::MORE).program(console: :snes), frames: 30)
  end
end
