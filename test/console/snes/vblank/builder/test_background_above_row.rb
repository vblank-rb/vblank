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

  # A STAGE LAID OUT AS A SUPER NINTENDO GAME LAYS ONE OUT: a bar held above row 32, over an arena of
  # two backgrounds, a floor and walls see-through in places, each scrolled its own way. The bar is
  # of two colours and covers its rows; the walls' steps show the floor's stripes through them.
  STAGE_ROWS = 32
  STRIPES = (0...8).map { |row| (0...8).map { |col| (col * 3) + row < 9 ? "#" : "." }.join }.freeze
  STEPS = (0...8).map { |row| (0...8).map { |col| col > row ? "#" : "." }.join }.freeze
  WALLS_SCROLL = [8, -25].freeze
  WHITE = 0x7FFF
  YELLOW = 0x03FF

  private def stage(size = 1)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:floor_art, "#" => :red, "." => :blue) { STRIPES.join("\n") }
      image(:wall_art, "#" => :green, "." => :transparent) { STEPS.join("\n") }
      image(:bar_art, "#" => :white, "." => :yellow) { STEPS.join("\n") }
      tiles :floor_tiles, "a" => :floor_art
      tiles :wall_tiles, "a" => :wall_art
      tiles :bar_tiles, "a" => :bar_art
      background(:floor, tiles: :floor_tiles, map: Array.new(32) { "a" * 32 }).scroll_to 0, 0
      background(:walls, tiles: :wall_tiles, map: Array.new(32) { "a" * 32 }).scroll_to(*WALLS_SCROLL)
      background :bar, tiles: :bar_tiles, map: Array.new(4) { "a" * 32 }, above_row: STAGE_ROWS
      game_loop { pixelate size, sprites: false }
    end
    b.finalize_program
    b.program
  end

  # What a player sees at (+x+, +y+) of the stage as drawn: the bar above its row, and below it the
  # walls where their steps are drawn and the floor through the rest, each at its own scroll.
  private def stage_pixel(x, y)
    return STEPS[y % 8][x % 8] == "#" ? WHITE : YELLOW if y < STAGE_ROWS

    arena_pixel(x, y)
  end

  # The arena alone at (+x+, +y+): the walls, and the floor through them.
  private def arena_pixel(x, y)
    across, down = WALLS_SCROLL
    return GREEN if STEPS[(y + down) % 8][(x + across) % 8] == "#"

    STRIPES[y % 8][x % 8] == "#" ? RED : BLUE
  end

  def test_a_bar_above_its_row_over_two_backgrounds_each_at_its_own_scroll
    screen = game_player.run(stage, frames: 4).screen
    spots = (0...240).step(3).flat_map { |x| (0...200).step(2).map { |y| [x, y] } }

    spots.each { |x, y| assert_equal stage_pixel(x, y), screen.pixel(x, y), "(#{x}, #{y})" }
  end

  # In blocks of 6, each layer in blocks at its own scroll: a block shows the pixel at its top left.
  # The block that straddles the row, rows 30 to 35, is the bar's on its rows above the row and,
  # from the row down, the arena as the block's first row reads it, since the console's count of a
  # block's lines runs on through the split.
  def test_a_bar_above_its_row_over_two_backgrounds_in_blocks
    screen = game_player.run(stage(6), frames: 4).screen
    spots = (0...240).step(5).flat_map { |x| (0...200).map { |y| [x, y] } }

    spots.each do |x, y|
      left = x - (x % 6)
      top = y - (y % 6)
      expected = y >= STAGE_ROWS && top < STAGE_ROWS ? arena_pixel(left, top) : stage_pixel(left, top)
      assert_equal expected, screen.pixel(x, y), "(#{x}, #{y})"
    end
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
