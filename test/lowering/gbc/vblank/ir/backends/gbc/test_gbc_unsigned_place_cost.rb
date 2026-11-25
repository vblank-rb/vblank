# frozen_string_literal: true

require "test_helper"
require "unsigned_place_cost_games"

# A pool's places in 256THS OF A PIXEL ON THE GAME BOY COLOR, measured in the emulator: places from
# 0 to 65535 kept with `& 0xFFFF`, which no signed slot holds, kept in two bytes read back with no
# sign (GBC::Lowering#unsigned_list?) and compared by the borrow out of their two bytes
# (GBC::Lowering::SmallNumbers). The console's processor works a byte at a time, so a place kept in
# four bytes is four loads and four stores each time it moves (Pan Docs, "CPU Instruction Set").
class TestGBCUnsignedPlaceCost < Minitest::Test
  # A frame's cycles at double speed: 154 lines of 912.
  FRAME_CYCLES = 140_448

  # Measured: a thing's step was 777 cycles with its places in four bytes, and 593 in two read
  # with no sign.
  def test_a_things_step_costs_under_630_cycles
    cost = UnsignedPlaceCostGames.cycles_a_thing(:gbc, FRAME_CYCLES)

    assert_operator cost, :<, 630, "a thing costs #{cost.round(1)} cycles"
  end

  # The places are the interpreter's on every pass.
  def test_the_places_are_the_interpreters_on_every_pass
    game_player.run(UnsignedPlaceCostGames.game(:gbc, UnsignedPlaceCostGames::MORE).program(console: :gbc), frames: 30)
  end
end
