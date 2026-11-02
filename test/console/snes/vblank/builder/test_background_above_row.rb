# frozen_string_literal: true

require "test_helper"

# A BACKGROUND HELD ABOVE A ROW OF THE SCREEN. A bar in the top rows slides inside them, and what is
# under them stays still and is never covered. Each row of the bar is a colour of its own, so a pixel
# says how far it has slid.
class TestBackgroundAboveRow < Minitest::Test
  ROWS = 32
  RED = 0x001F
  BLUE = 0x7C00
  GREEN = 0x03E0

  private def sliding
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:field_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:top_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:low_tile, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      tiles :field_set, "#" => :field_tile
      tiles :bar_set, "t" => :top_tile, "l" => :low_tile
      layers :under, :over
      layer(:under) { background :field, tiles: :field_set, map: Array.new(32) { "#" * 32 } }
      layer :over do
        bar = background :bar, tiles: :bar_set, map: Array.new(4) { "t" * 32 } + Array.new(4) { "l" * 32 }, above_row: ROWS
        slid = var :slid, 0
        changes = var :changes, 0
        game_loop do
          changes += 1
          slid += 4 if held(:a) && slid < 32
          bar.scroll_to 0, slid
          bar.set_tile 0, 0, "l" if changes == 6
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Only the first scene holds one, so the second has both layers on every row again.
  private def two_scenes
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:field_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:top_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      tiles :field_set, "#" => :field_tile
      tiles :bar_set, "t" => :top_tile
      state = var :state, 0
      passes = var :passes, 0
      scene(:held) do
        background :full, tiles: :bar_set, map: Array.new(8) { "t" * 32 }, above_row: ROWS
      end
      scene(:plain) do
        background :free, tiles: :bar_set, map: Array.new(8) { "t" * 32 }
      end
      game_loop do
        passes += 1
        state = 1 if passes == 6
        case_var(:state) do
          when_val 0, :held
          when_val 1, :plain
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_a_background_shows_only_above_its_row
    run = game_player.run(sliding, frames: 8)

    assert_equal RED, run.screen.pixel(100, ROWS - 1)
    refute_equal RED, run.screen.pixel(100, ROWS)
    assert_equal GREEN, run.screen.pixel(100, ROWS)
  end

  def test_it_scrolls_inside_its_rows_and_the_rows_under_them_stay
    run = game_player.hold(:a).run(sliding, frames: 16)

    assert_equal BLUE, run.screen.pixel(100, 0)
    assert_equal BLUE, run.screen.pixel(100, ROWS - 1)
    assert_equal GREEN, run.screen.pixel(100, ROWS)
  end

  def test_a_cell_changed_shows_inside_its_rows
    run = game_player.run(sliding, frames: 10)

    assert_equal BLUE, run.screen.pixel(4, 4)
  end

  def test_a_scene_after_it_has_the_whole_screen
    run = game_player.run(two_scenes, frames: 16)

    assert_equal RED, run.screen.pixel(100, ROWS + 4)
  end
end
