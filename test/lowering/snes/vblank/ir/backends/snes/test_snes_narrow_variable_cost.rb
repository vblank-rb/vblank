# frozen_string_literal: true

require "test_helper"
require "narrow_variable_cost_games"

# VARIABLES PROVEN TO STAY IN 16 BITS ON THE SUPER NINTENDO, measured in the emulator: each kept in
# two bytes (SNES::HalfVariables), set with its low half worked out alone and one STA
# (SNES::Lowering#emit_set_half), where a whole number is two loads, two stores and an add of each
# half. The 65816 works 16 bits at a time with its accumulator wide, and the console's own games
# keep such numbers in one word (fullsnes, "CPU 65XX Microprocessor").
class TestSNESNarrowVariableCost < Minitest::Test
  # A frame's master clocks: 262 lines of 1364.
  FRAME_CLOCKS = 262 * 1364

  # Measured: a turn of three numbers masked to ten, eleven and twelve bits was 920 master clocks
  # with each kept in four bytes, and 411 in two.
  def test_a_turn_working_three_small_numbers_costs_under_440_master_clocks
    cost = NarrowVariableCostGames.cycles_a_turn(:snes, FRAME_CLOCKS)

    assert_operator cost, :<, 440, "a turn costs #{cost.round(1)} master clocks"
  end

  # The numbers are the interpreter's on every pass.
  def test_the_numbers_are_the_interpreters_on_every_pass
    game_player.run(NarrowVariableCostGames.game(:snes, 32).program(console: :snes), frames: 10)
  end
end
