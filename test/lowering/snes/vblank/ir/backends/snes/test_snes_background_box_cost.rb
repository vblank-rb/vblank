# frozen_string_literal: true

require "test_helper"
require "stringio"

# A BACKGROUND HELD TO A BOX (`show_only_inside`), on the Super Nintendo, costs nothing while the
# screen is drawn: the display's windows hide the layer outside the box, and a copying channel writes
# the window's edges a line at a time from a short table (Runtime::BackgroundBox, fullsnes "SNES PPU
# Window"). What the processor spends is the box written at each frame boundary, and the table made
# again in the blank on a pass the box moved. A console game moving a window spends the same: its
# table of edges, a few steps, written when the window moves.
class TestSNESBackgroundBoxCost < Minitest::Test
  FRAMES = 30

  # A layer of red in front of one of green; +box+ :none holds no box, :still the same box every
  # pass, :moving a box that slides and grows a pixel a pass. Every one works out where the moving
  # box would be, so what the three differ by is the box alone.
  private def boxed_game(box)
    VBlank.game("BOX #{box.upcase}", consoles: %i[snes]) do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :sky_set, "#" => :green_tile
      tiles :box_set, "#" => :red_tile
      layers :back, :front
      layer(:back) { background :sky, tiles: :sky_set, map: Array.new(32) { "#" * 32 } }
      layer :front do
        dialogue = background :dialogue, tiles: :box_set, map: Array.new(32) { "#" * 32 }
        passes = var :passes, 0
        across = var :across, 0
        tall = var :tall, 0
        game_loop do
          passes += 1
          across.store!(40 + (passes & 63))
          tall.store!(60 + (passes & 63))
          dialogue.show_only_inside 40, 40, 160, 100 if box == :still
          dialogue.show_only_inside across, 20, 100, tall if box == :moving
        end
      end
    end
  end

  private def awake_share(game)
    rom = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)
    1 - rom.profile(out: StringIO.new, frames: FRAMES).idle_share
  end

  # THE BUDGET for a box that stays still: the verb's five numbers kept each pass, and handed at the
  # frame boundary to rt_background_box, which compares them with the last ones and finds nothing
  # changed. Some five hundred of the processor's cycles, of a frame's 262 lines of 1364 clocks:
  # under one per cent of a frame. Kept to the screen in the lowered code before each call, as the
  # first build did, a still box cost two and a half times this.
  MOST_SHARE_STILL_BOX = 0.01

  def test_a_still_box_costs_its_write_at_the_frame_boundary
    none = awake_share(boxed_game(:none))
    still = awake_share(boxed_game(:still)) - none

    assert_operator still, :<, MOST_SHARE_STILL_BOX, "a still box costs #{(still * 100).round(3)}% of a frame"
  end

  # THE BUDGET for a box that moves every pass: the still box's write, the box kept to the screen in
  # 32 bits (four clamps), and the table of at most five steps made again in the blank with the
  # window registers: some seven hundred cycles more than a still box, under two and a half per cent
  # of a frame. A console game moving a window writes the same table.
  MOST_SHARE_MOVING_BOX = 0.025

  def test_a_moving_box_costs_its_table_made_again_in_the_blank
    none = awake_share(boxed_game(:none))
    moving = awake_share(boxed_game(:moving)) - none

    assert_operator moving, :<, MOST_SHARE_MOVING_BOX, "a moving box costs #{(moving * 100).round(3)}% of a frame"
  end
end
