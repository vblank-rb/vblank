# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/builder/test_draw_in_order"

# AN ORDER OF MORE THAN 128 THINGS, which only the Advance can keep: it has places for 512
# sprites, and the other consoles fewer than the 132 here. The order keeps each thing's place in
# a list, and past the 128th a place no longer fits in a byte. The games are DrawInOrderGames'.
class TestDrawInOrderOnTheAdvance < Minitest::Test
  include Differential
  include DrawInOrderGames

  RED = VBlank::Graphics::Color.resolve(:red)
  GREEN = VBlank::Graphics::Color.resolve(:green)

  OVERLAP = [70, 66].freeze

  private def shown(prog) = game_player.run(prog, frames: 2).screen.pixel(*OVERLAP)

  def test_an_order_of_more_than_128_things_keeps_whoever_stands_lower_in_front
    assert_equal RED, shown(crowded_program(54)), "the hero stands higher, so the enemy covers him"
    assert_equal GREEN, shown(crowded_program(66)), "the hero stands lower, so he covers the enemy"
    assert_backends_agree(crowded_program(66), frames: 2)
  end
end
