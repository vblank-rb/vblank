# frozen_string_literal: true

require "test_helper"

# Backgrounds drawn from 16×16 TILES, which a Super Nintendo draws itself: each background says the
# size of its tiles, and a cell of its map is one tile of that size. A game brought over from a
# Super Nintendo cartridge has them (Super Bomberman draws its first two backgrounds from 16×16
# tiles and its third from 8×8). The Advance and the Color draw 8×8 tiles only.
class TestBigBackgroundTilesOnTheSuperNintendo < Minitest::Test
  GREEN = Color.resolve(:green)
  BLUE = Color.resolve(:blue)
  RED = Color.resolve(:red)
  WHITE = Color.resolve(:white)
  YELLOW = Color.resolve(:yellow)

  # A 16×16 tile whose four quarters are four colours, so a quarter drawn in the wrong place shows.
  QUARTERS = ((["g" * 8 + "b" * 8] * 8) + (["r" * 8 + "w" * 8] * 8)).join("\n")

  # A screen of the four-quarter tile; the block is handed its background.
  private def program(&extra)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:quarters, "g" => :green, "b" => :blue, "r" => :red, "w" => :white) { QUARTERS }
      image(:plain, "w" => :white) { (["w" * 16] * 16).join("\n") }
      tiles :big, "#" => :quarters, "w" => :plain
      field = background :field, tiles: :big, map: Array.new(14) { "#" * 16 }
      instance_exec(field, &extra) if extra
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_cell_is_one_16x16_tile_with_its_quarters_in_place
    screen = game_player.run(program, frames: 3).screen

    assert_equal [GREEN, BLUE, RED, WHITE], [[4, 4], [12, 4], [4, 12], [12, 12]].map { |x, y| screen.pixel(x, y) }
    assert_equal GREEN, screen.pixel(20, 20), "the next cell along and down"
  end

  # Scrolled half a tile along, the blue quarter is where the green one was.
  def test_a_background_of_16x16_tiles_scrolls_by_pixels
    prog = program { |field| field.scroll_to 8, 0 }
    screen = game_player.run(prog, frames: 3).screen

    assert_equal BLUE, screen.pixel(4, 4)
  end

  # A cell changed as the game runs shows another whole 16×16 tile.
  def test_a_cell_changed_as_the_game_runs_is_a_whole_tile
    prog = program { |field| field.set_tile 1, 1, "w" }
    screen = game_player.run(prog, frames: 3).screen

    assert_equal [WHITE, WHITE], [screen.pixel(20, 20), screen.pixel(28, 20)]
    assert_equal GREEN, screen.pixel(36, 20), "the cell after it"
  end

  # One background of 16×16 tiles in front of one of 8×8, as Super Bomberman has them.
  def test_a_background_of_8x8_tiles_beside_one_of_16x16
    prog = program do
      image(:dot, "y" => :yellow, "." => :black) { ((["yyyy...."] * 4) + (["........"] * 4)).join("\n") }
      tiles :small, "y" => :dot
      background :hud, tiles: :small, map: Array.new(28) { "y" * 32 }
    end
    screen = game_player.run(prog, frames: 3).screen

    assert_equal YELLOW, screen.pixel(9, 9), "the 8×8 background's dot, in front"
    assert_equal WHITE, screen.pixel(13, 13), "the 16×16 background behind it, where the dot is see-through"
  end
end
