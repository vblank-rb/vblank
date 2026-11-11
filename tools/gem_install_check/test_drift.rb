# frozen_string_literal: true

require "vblank/testing"
require_relative "drift"

# Played once per lowering (VBLANK_LOWERING): on DOS the program runs in DOSBox, checked against the
# interpreter after every pass.
class TestDrift < Minitest::Test
  include VBlank::Testing

  def test_the_block_drifts_a_pixel_a_pass
    played = game_player.run(Drift.program(console: game_console), frames: 6)

    assert_equal 46, played[:x]
  end
end
