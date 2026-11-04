# frozen_string_literal: true

require "test_helper"
require "all/vblank/dsl/test_held_tiles"

# THE QUEUE A HELD BACKGROUND'S CHANGES WAIT IN, on the runs that play games as the Advance. A pass
# can make more changes than the queue holds (IR::Nodes::ShowHeldTiles::MOST_CELLS), and then the
# changes waiting go in at once, so every change still lands in the order it was made. The other
# consoles write a pass's changes in a queue of their own, and a Color, Super Nintendo or Genesis
# pass this big is past what their queues hold (each one's answers table, `background`).
#
# ...and a scene taking over beside a held box every screen shows (HeldTilesSceneTests).
class TestHeldTilesOnTheAdvance < Minitest::Test
  include HeldTilesGames
  include HeldTilesSceneTests

  def test_changes_past_what_waits_at_once_all_show_in_the_order_made
    screen = game_player.run(tree_of(overflowing_game), frames: 4).screen
    assert_equal Color.resolve(:green), cell_color(screen, 0, 0), "the last change to the cell is the one showing"
    assert_equal Color.resolve(:blue), cell_color(screen, 1, 0), "a change after the queue filled shows too"
    assert_equal Color.resolve(:red), cell_color(screen, 2, 0), "and nothing else changed"
  end
end
