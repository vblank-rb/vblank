# frozen_string_literal: true

require "test_helper"
require "pixelate_backgrounds_tests"

# THE BACKGROUNDS IN BLOCKS AND THE SPRITES AS DRAWN, on the Super Nintendo, whose mosaic reaches
# the backgrounds and never the sprites: the tests every console whose display can show it plays
# (PixelateBackgroundsTests in test/pixelate_backgrounds_tests.rb). The Advance's twin is
# test/console/gba/vblank/builder/test_pixelate_backgrounds_on_the_advance.rb.
#
# The tests below it are of a background held above a row (`above_row:`), which of the cartridges
# only the Super Nintendo's builds. So they are played by the runs that play games as the Super
# Nintendo: its cartridge, and the game as C, JavaScript and Ruby.
class TestPixelateBackgroundsOnTheSuperNintendo < Minitest::Test
  include PixelateBackgroundsTests

  # A bar held above a row that no size here divides, over a room that scrolls every pass, in
  # blocks of +size+ from the first pass. Without +held+ the room alone.
  BAR_ROWS = 20

  private def room_under_a_held_bar(size, held: true)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      image(:bar_art, "#" => :yellow, "." => :black) { STRIPES }
      tiles :set, "a" => :stripes, "b" => :steps
      tiles :bar_tiles, "a" => :bar_art, "b" => :steps
      room = background(:room, tiles: :set, map: ROOM)
      background :bar, tiles: :bar_tiles, map: ROOM.first(4), above_row: BAR_ROWS if held
      across = var :across, 0
      game_loop do
        across += 3
        room.scroll_to across, across / 2
        pixelate size, sprites: false
      end
    end
    b.finalize_program
    b.program
  end

  # One grid of blocks from the screen's top, straight through the bar's last row: the console's
  # mosaic counts its lines down the whole screen, and the line table that ends the bar changes
  # which layers show, never the count. So a block that starts on the bar's rows and ends below
  # them shows, on its rows below the bar, the room as the block's first row reads it: below the
  # bar the picture is the room's alone, in the blocks it has with no bar at all.
  def test_the_room_under_a_held_bar_keeps_the_grid_from_the_screens_top
    [3, 8].product([2, 5]).each do |size, frames|
      screen = game_player.run(room_under_a_held_bar(size), frames: frames).screen
      alone = game_player.run(room_under_a_held_bar(size, held: false), frames: frames).screen
      below = (0...200).step(3).flat_map { |x| (BAR_ROWS...150).map { |y| [x, y] } }

      assert_equal(below.map { |x, y| alone.pixel(x, y) }, below.map { |x, y| screen.pixel(x, y) },
                   "blocks of #{size}, frame #{frames}: below the bar, the room in its own blocks")
      (0...200).step(3).flat_map { |x| (0...BAR_ROWS).map { |y| [x, y] } }.each do |x, y|
        assert_equal screen.pixel(x - (x % size), y - (y % size)), screen.pixel(x, y),
                     "blocks of #{size}, frame #{frames}: the bar's (#{x}, #{y})"
      end
      assert_operator below.map { |x, y| screen.pixel(x, y) }.uniq.size, :>, 1
    end
  end

  # A stage laid out as Super Nintendo games lay one out: a bar 32 rows tall held above its last
  # row, over an arena that does not scroll. The blocks grow a size a pass, from 2, so most sizes
  # do not divide the bar's height, and a block straddles the bar's last row on all of those.
  ARENA_BAR_ROWS = 32

  private def arena_under_a_held_bar(grows: true, held: true)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      image(:bar_art, "#" => :yellow, "." => :black) { STRIPES }
      tiles :set, "a" => :stripes, "b" => :steps
      tiles :bar_tiles, "a" => :bar_art, "b" => :bar_art
      background(:arena, tiles: :set, map: ROOM).scroll_to 0, 0
      background(:bar, tiles: :bar_tiles, map: ROOM.first(4), above_row: ARENA_BAR_ROWS).scroll_to 0, 0 if held
      size = var :size, 1
      game_loop do
        size.approach! 15, 1 if grows
        pixelate size, sprites: false
      end
    end
    b.finalize_program
    b.program
  end

  # Each size from 2 to 15: from the bar's last row down the picture is
  # the arena's alone, in its own blocks from the screen's top, the rows of a straddling block too,
  # which read the arena at the block's first row as the console's display does.
  def test_an_arena_under_a_32_row_bar_in_blocks_of_every_size
    program = arena_under_a_held_bar
    sharp = game_player.run(arena_under_a_held_bar(grows: false, held: false), frames: 2).screen
    (1..14).each do |frames|
      run = game_player.run(program, frames: frames)
      screen = run.screen
      size = run[:size] - framework_drawing_lag
      (0...240).step(5).each do |x|
        (ARENA_BAR_ROWS...200).each do |y|
          assert_equal sharp.pixel(x - (x % size), y - (y % size)), screen.pixel(x, y), "blocks of #{size}: (#{x}, #{y})"
        end
      end
    end
  end

  # Two tiles in seven colours whose every pixel differs from its neighbours inside the tile, so a
  # block that reads one column or one row off shows the wrong colour.
  SEVEN_COLOR_KEY = Ractor.make_shareable(%i[red green blue yellow cyan magenta white].each_with_index.to_h { |name, i| [i.to_s, name] })
  CROSSED = Ractor.make_shareable((0...8).map { |row| (0...8).map { |col| ((col + (3 * row)) % 7).to_s }.join }.join("\n"))
  SLANTED = Ractor.make_shareable((0...8).map { |row| (0...8).map { |col| (((2 * col) + row + 1) % 7).to_s }.join }.join("\n"))
  # A map 512 pixels tall, as a Super Nintendo stage keeps its arena.
  TALL_ARENA = Ractor.make_shareable((0...64).map { |row| (0...32).map { |col| (((row * 5) + col) % 3) == 1 ? "a" : "b" }.join })

  # The arena scrolled to (+across+, +down+) under the 32-row bar, in blocks of +size+. Without
  # +held+ the arena alone.
  private def scrolled_arena(size, across, down, held: true)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:crossed, SEVEN_COLOR_KEY) { CROSSED }
      image(:slanted, SEVEN_COLOR_KEY) { SLANTED }
      image(:bar_art, "#" => :yellow, "." => :black) { STRIPES }
      tiles :set, "a" => :crossed, "b" => :slanted
      tiles :bar_tiles, "a" => :bar_art, "b" => :bar_art
      background(:arena, tiles: :set, map: TALL_ARENA).scroll_to across, down
      background(:bar, tiles: :bar_tiles, map: ROOM.first(4), above_row: ARENA_BAR_ROWS).scroll_to 0, 0 if held
      game_loop { pixelate size, sprites: false }
    end
    b.finalize_program
    b.program
  end

  # A SCROLLED ARENA keeps the grid fixed to the screen: every block shows the pixel the arena has,
  # as drawn, at the block's top left on the screen, wherever the scroll puts the map: from the bar's
  # last row down, the arena alone in its own blocks, a block that straddles that row read at its
  # first row. The scrolls: a whole tile across and far down a 512-row map (the cartridge writes
  # BG1HOFS 8 and BG1VOFS 487, a row less, as Runtime::Picture says), one off the tile grid both
  # ways, and one that wraps past the map's top. On the snes run the cartridge's picture in bsnes is
  # held to the interpreter's on every pass, which is the answer key for the console's mosaic
  # (sfc/ppu/background.cpp, PPU::Background::run counts a block's columns from the screen's column
  # 0 after the scroll; fetchNameTable reads the line less the mosaic's count, plus the scroll).
  def test_a_scrolled_arena_under_the_bar_is_in_blocks_fixed_to_the_screen
    sizes = [3, 6, 7]
    [[8, 488], [3, 5], [8, -25]].each do |across, down|
      sharp = game_player.run(scrolled_arena(1, across, down, held: false), frames: 2).screen
      spots = (0...256).flat_map { |x| (ARENA_BAR_ROWS...224).step(2).map { |y| [x, y] } }
      assert_operator spots.map { |x, y| sharp.pixel(x, y) }.uniq.size, :>, 2
      sizes.each do |size|
        screen = game_player.run(scrolled_arena(size, across, down), frames: 2).screen
        spots.each do |x, y|
          assert_equal sharp.pixel(x - (x % size), y - (y % size)), screen.pixel(x, y),
                       "scroll (#{across}, #{down}), blocks of #{size}: (#{x}, #{y})"
        end
      end
    end
  end

  # A menu with a status bar as drawn beside its room, and a stage with clouds over the room in that
  # layer: the layer is in blocks on the stage and not on the menu, and the game goes from one to the
  # other and back.
  private def menu_then_stage(size = 5)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :transparent) { STEPS }
      image(:bar_art, "#" => :yellow, "." => :black) { STRIPES }
      tiles :set, "a" => :stripes, "b" => :stripes
      tiles :cloud_tiles, "a" => :steps, "b" => :steps
      tiles :bar_tiles, "a" => :bar_art, "b" => :bar_art
      background(:room, tiles: :set, map: ROOM).scroll_to 5, 3
      state = var :state, 0
      step = var :step, 0
      scene(:menu) { status_bar :score, tiles: :bar_tiles, map: ROOM.first(2), top: screen_height - 16 }
      scene(:stage) { background(:clouds, tiles: :cloud_tiles, map: ROOM).scroll_to 2, 1 }
      game_loop do
        step += 1
        state = 1 if step == 4
        state = 0 if step == 9
        pixelate size, sprites: false
        case_var(:state) do
          when_val 0, :menu
          when_val 1, :stage
        end
      end
    end
    b.finalize_program
    b.program
  end

  # On every frame, on either screen, the room and the clouds are in blocks, and the menu's bar, on
  # the clouds' layer, is as drawn: before the stage and after it.
  def test_a_layer_in_blocks_in_one_scene_and_not_another
    program = menu_then_stage
    [3, 7, 12].each do |frames|
      run = game_player.run(program, frames: frames)
      room_spots.each do |x, y|
        assert_equal run.screen.pixel(x - (x % 5), y - (y % 5)), run.screen.pixel(x, y), "frame #{frames}: (#{x}, #{y})"
      end
    end
    [3, 12].each do |frames|
      blocky = game_player.run(program, frames: frames).screen
      sharp = game_player.run(menu_then_stage(1), frames: frames).screen
      bar = (0...200).step(3).flat_map { |x| (210...224).map { |y| [x, y] } }

      assert_equal(bar.map { |x, y| sharp.pixel(x, y) }, bar.map { |x, y| blocky.pixel(x, y) },
                   "frame #{frames}: the menu's bar is as drawn")
    end
  end
end
