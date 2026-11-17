# frozen_string_literal: true

require "test_helper"
require "sprite_count_cost_games"

# WHAT SPRITES NOT SHOWING COST ON THE GAME BOY COLOR, measured in the emulator. A sprite not
# showing is a test of whether it shows; the budget for one is a test of four bytes and a branch,
# sixteen machine cycles, so thirty-two of them are under two and a half of the frame's 154 lines.
# The sprite table's copy is switched off past the last entry a pass wrote only where the pass
# before wrote (Runtime::Picture#emit_sprites), so a pass that drops no sprite switches none off.
class TestGBCSpriteCountCost < Minitest::Test
  LINES = 154
  BOUND_THIRTY_TWO = 2.5

  def test_thirty_two_sprites_not_showing_cost_a_test_each
    share = SpriteCountCostGames.share_beyond(:gbc, SpriteCountCostGames.sprites_game(:gbc, 36),
                                              SpriteCountCostGames.sprites_game(:gbc, 4))

    assert_operator share * LINES, :<, BOUND_THIRTY_TWO, "thirty-two sprites not showing cost #{(share * LINES).round(2)} lines"
  end

  # Measured: five lines before each place's test was asked a part at a time (ShownWhen).
  def test_thirty_two_empty_places_of_a_pool_cost_a_test_each
    share = SpriteCountCostGames.share_beyond(:gbc, SpriteCountCostGames.pool_game(:gbc, 36),
                                              SpriteCountCostGames.pool_game(:gbc, 4))

    assert_operator share * LINES, :<, BOUND_THIRTY_TWO, "thirty-two empty places cost #{(share * LINES).round(2)} lines"
  end

  # Measured: a line and a half every pass, switching off the thirty-six entries past the four
  # sprites' own, before only the entries the pass before wrote were switched off.
  def test_a_pass_that_drops_no_sprite_switches_none_off
    result = SpriteCountCostGames.profile(:gbc, SpriteCountCostGames.sprites_game(:gbc, 4))
    share = result.runtime.select { |row| row.routine.to_s == "rt_sprites_end_next" }.sum(&:share)

    assert_operator share * LINES, :<, 0.2, "switching entries off takes #{(share * LINES).round(2)} lines"
  end
end
