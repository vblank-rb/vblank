# frozen_string_literal: true

require "test_helper"
require "draw_order_cost_games"

# WHAT AN ORDER COSTS ON THE SUPER NINTENDO, measured in the emulator. The console's own games sort
# every sprite on the screen by height each frame, about ten instructions a sprite, so an order of
# seven must cost its tightest frame, where two things pass each other and the sort moves one, a
# few of the frame's 262 lines, not the thirty it cost written as list reads and writes, and an
# order of thirty must leave most of the frame to the game.
#
# The seven's bound is under three lines for the sort, and a third of a line more for asking
# whether each of the pool's three places shows, so things not showing are left out of the sort
# and its walk (Lowering::ShownSort): three and a quarter together. The sort keeps its tables as its direct page only while every
# number is read where it is, a pool's place kept in half words among them
# (Lowering#key_low_half_in_place?); worked out whole, it took the seven past three lines.
class TestSNESDrawInOrderCost < Minitest::Test
  BOUND_SEVEN = 3.25
  BOUND_THIRTY = 28

  def test_an_order_of_seven_costs_its_tightest_frame_a_few_lines
    cost = DrawOrderCostGames.lines_off_tightest_frame(:snes, sprites: 4)

    assert_operator cost, :<=, BOUND_SEVEN, "an order of seven costs its tightest frame #{cost.round(2)} lines"
  end

  def test_an_order_of_thirty_costs_under_a_ninth_of_the_frame
    cost = DrawOrderCostGames.lines_off_tightest_frame(:snes, sprites: 27)

    assert_operator cost, :<, BOUND_THIRTY, "an order of thirty costs #{cost.round(2)} lines"
  end

  # A pool of 32 whose whole order turns round every pass, every thing passing every other, still
  # keeps a pass a frame: the sort turns a run of things that stand the wrong way round over at
  # once rather than moving each back a place at a time (Lowering#emit_keyed_sort).
  def test_a_pool_of_thirty_two_whose_order_turns_round_takes_a_frame_a_pass
    passes = DrawOrderCostGames.passes_by_frames(:snes, DrawOrderCostGames.reversed_pool_game(:snes, 32))

    assert_equal({ 1 => 20 }, passes, "every pass fits in one frame")
  end

  # The same pool drawn in the interpreter's order on every pass: the checked run compares the
  # sprites drawn, back to front, after each one, and stops at the first that differs. The first
  # thing spawned stands at the top left or, turned upside down, 127 pixels below it.
  def test_a_pool_of_thirty_two_whose_order_turns_round_is_drawn_as_the_interpreter_draws_it
    shown = game_player.run(DrawOrderCostGames.reversed_pool_game(:snes, 32).program, frames: 8).screen

    assert_includes [[8, 8], [8, 135]].map { |at| shown.pixel(*at) }, VBlank::Graphics::Color.resolve(:red)
  end
end
