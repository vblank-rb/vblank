# frozen_string_literal: true

require "test_helper"
require "narrow_variable_cost_games"

# Variables proven to stay in 16 bits on the Game Boy Color, measured in the emulator: each kept in
# two bytes (GBC::NarrowVariables), worked out two bytes at a time (WrittenNumbers#low_value), and a
# mask's byte of all ones or of nought left out (WrittenNumbers#byte_kept_by?). The console's
# processor works a byte at a time, so a number kept in four is four loads and four stores each
# time it is written (Pan Docs, "CPU Instruction Set").
class TestGBCNarrowVariableCost < Minitest::Test
  # A frame's cycles at double speed: 154 lines of 912.
  FRAME_CYCLES = 140_448

  # Measured: a turn of three numbers masked to ten, eleven and twelve bits was 596 cycles with
  # each kept in four bytes, and 500 in two.
  def test_a_turn_working_three_small_numbers_costs_under_520_cycles
    cost = NarrowVariableCostGames.cycles_a_turn(:gbc, FRAME_CYCLES)

    assert_operator cost, :<, 520, "a turn costs #{cost.round(1)} cycles"
  end

  # The numbers are the interpreter's on every pass.
  def test_the_numbers_are_the_interpreters_on_every_pass
    game_player.run(NarrowVariableCostGames.game(:gbc, 32).program(console: :gbc), frames: 10)
  end
end
