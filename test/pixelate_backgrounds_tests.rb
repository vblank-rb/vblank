# frozen_string_literal: true

# THE BACKGROUNDS IN BLOCKS AND THE SPRITES AS DRAWN (`pixelate size, sprites: false`), on every
# console whose display can show it: the Advance, which keeps "in blocks" as a switch on each
# background and each sprite, and the Super Nintendo, whose mosaic reaches the backgrounds and never
# the sprites. Each console's folder has a test file that includes these, so they are written once
# and played on every run that plays games as either console:
#
#   test/console/gba/vblank/builder/test_pixelate_backgrounds_on_the_advance.rb
#   test/console/snes/vblank/builder/test_pixelate_backgrounds_on_the_super_nintendo.rb
#
# The game is the look a Super Nintendo game gives a stage's end: the screen fades to black a level
# a frame, and the blocks grow a pixel a frame as it does.
module PixelateBackgroundsTests
  include SharedConstants

  # Two tiles with nothing flat about them, so a block's colour depends on where it starts.
  STRIPES = VBlank::Testing::InRactors.shareable((0...8).map { |row| (0...8).map { |col| (col * 3) + row < 9 ? "#" : "." }.join }.join("\n"))
  STEPS = VBlank::Testing::InRactors.shareable((0...8).map { |row| (0...8).map { |col| col > row ? "#" : "." }.join }.join("\n"))
  ROOM = VBlank::Testing::InRactors.shareable((0...32).map { |row| (0...32).map { |col| (((row * 2) + col) % 3).zero? ? "a" : "b" }.join })

  # A 16x16 sprite with a different colour at every corner and holes along two edges.
  PATCH = VBlank::Testing::InRactors.shareable((0...16).map do |row|
    (0...16).map do |col|
      next "." if (col.zero? && row.even?) || (col == 15 && row < 4)

      "ABCD"[(col + (2 * row)) % 4]
    end.join
  end.join("\n"))
  PATCH_COLORS = VBlank::Testing::InRactors.shareable({ "." => :transparent, "A" => :red, "B" => :green, "C" => :blue, "D" => :white })

  HERO = VBlank::Testing::InRactors.shareable([37, 21])
  HERO_SIZE = 16

  # The room scrolled off the tile grid, the hero standing on it, and a fade to black begun on the
  # first pass. With +blocks+ the blocks grow by one each pass, to the biggest, the sprites kept out.
  private def fading_room(blocks:)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      image(:patch, PATCH_COLORS) { PATCH }
      tiles :set, "a" => :stripes, "b" => :steps
      background(:room, tiles: :set, map: ROOM).scroll_to 5, 3
      sprite :hero, at: HERO, facing: { right: :patch }
      size = var :size, 1
      started = var :started, 0
      game_loop do
        started += 1
        fade_out frames: 15 if started == 1
        if blocks
          size.approach! 16, 1
          pixelate size, sprites: false
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Pixels of the room well away from the hero, so every block they are in starts away from it too.
  private def room_spots = (120...200).step(3).flat_map { |x| (80...140).step(5).map { |y| [x, y] } }

  # Every frame of the fade, each of the room's pixels shows the colour at the top left of its block:
  # the blocks are fixed to the screen, whatever the scroll.
  def test_the_room_is_in_blocks_fixed_to_the_screen_as_the_screen_fades
    prog = fading_room(blocks: true)
    (2..14).each do |frames|
      run = game_player.run(prog, frames: frames)
      size = run[:size]
      screen = run.screen

      assert_operator size, :>, 1
      room_spots.each do |x, y|
        assert_equal screen.pixel(x - (x % size), y - (y % size)), screen.pixel(x, y),
                     "frame #{frames}, blocks of #{size}: (#{x}, #{y}) shows its block's top left"
      end
      assert_operator room_spots.map { |x, y| screen.pixel(x, y) }.uniq.size, :>, 1,
                      "frame #{frames}: the blocks are not all one colour"
    end
  end

  # A room that scrolls every pass, under a status bar of its own tiles, in blocks of +size+.
  private def walking_room(size)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      tiles :set, "a" => :stripes, "b" => :steps
      image(:patch, PATCH_COLORS) { PATCH }
      tiles :bar_tiles, "a" => :steps, "b" => :stripes
      room = background(:room, tiles: :set, map: ROOM)
      status_bar :score, tiles: :bar_tiles, map: ROOM.first(2), top: screen_height - 16
      sprite :hero, at: HERO, facing: { right: :patch }
      var :wide, screen_width
      var :tall, screen_height
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

  # The room slides under blocks that stay where they are, and the status bar stays as drawn.
  def test_a_scrolling_room_slides_under_blocks_fixed_to_the_screen_and_the_bar_is_left_as_drawn
    [3, 7].product([2, 5]).each do |size, frames|
      run = game_player.run(walking_room(size), frames: frames)
      screen = run.screen
      room_spots.each do |x, y|
        assert_equal screen.pixel(x - (x % size), y - (y % size)), screen.pixel(x, y),
                     "blocks of #{size}, frame #{frames}: (#{x}, #{y})"
      end
      bar_row = run[:tall] - 12
      sharp = game_player.run(walking_room(1), frames: frames).screen
      row_of = ->(picture) { (0...run[:wide]).map { |x| picture.pixel(x, bar_row) } }

      assert_equal row_of.call(sharp), row_of.call(screen), "blocks of #{size}, frame #{frames}: the bar is as drawn"
    end
  end

  # A room under a status bar whose top no size here divides, the bar in blocks too.
  private def room_over_a_bar_in_blocks(size, bar_in_blocks: true)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :white) { STEPS }
      tiles :set, "a" => :stripes, "b" => :steps
      tiles :bar_tiles, "a" => :steps, "b" => :stripes
      room = background(:room, tiles: :set, map: ROOM)
      status_bar :score, tiles: :bar_tiles, map: ROOM.first(3), top: screen_height - 21
      var :tall, screen_height
      across = var :across, 0
      game_loop do
        across += 3
        room.scroll_to across, across / 2
        pixelate size, sprites: false, status_bar: bar_in_blocks
      end
    end
    b.finalize_program
    b.program
  end

  # `status_bar: true`: the bar is in blocks of the one grid from the screen's top. A block that
  # starts above the bar's top shows, on its rows from the bar down, the bar's layer read at the
  # block's first row, which is above the bar's map: nothing of the bar is there, so the backdrop
  # shows (black, as nothing here sets one).
  def test_a_status_bar_in_blocks_keeps_the_grid_from_the_screens_top
    [3, 8].product([2, 5]).each do |size, frames|
      run = game_player.run(room_over_a_bar_in_blocks(size), frames: frames)
      screen = run.screen
      bar_top = run[:tall] - 21
      bar = (0...200).step(3).flat_map { |x| (bar_top...run[:tall]).map { |y| [x, y] } }
      straddling, inside = bar.partition { |_, y| y - (y % size) < bar_top }

      assert_operator straddling.size, :>, 0
      straddling.each { |x, y| assert_equal 0, screen.pixel(x, y), "blocks of #{size}, frame #{frames}: (#{x}, #{y})" }
      inside.each do |x, y|
        assert_equal screen.pixel(x - (x % size), y - (y % size)), screen.pixel(x, y),
                     "blocks of #{size}, frame #{frames}: the bar's (#{x}, #{y}) shows its block's top left"
      end
      sharp = game_player.run(room_over_a_bar_in_blocks(size, bar_in_blocks: false), frames: frames).screen

      refute_equal(inside.map { |x, y| sharp.pixel(x, y) }, inside.map { |x, y| screen.pixel(x, y) },
                   "blocks of #{size}, frame #{frames}: the bar is in blocks")
    end
  end

  # Two backgrounds, the front one see-through in places, under a status bar along the top: the
  # layout of a Super Nintendo game's stage, whose bar is on a third layer. Both backgrounds are in
  # blocks, each by itself, and the bar is not.
  def test_two_backgrounds_under_a_bar_along_the_top_are_each_in_blocks
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:stripes, "#" => :red, "." => :blue) { STRIPES }
      image(:steps, "#" => :green, "." => :transparent) { STEPS }
      image(:bar_art, "#" => :white, "." => :black) { STEPS }
      tiles :floor_tiles, "a" => :stripes, "b" => :stripes
      tiles :wall_tiles, "a" => :steps, "b" => :steps
      tiles :bar_tiles, "a" => :bar_art, "b" => :bar_art
      background(:floor, tiles: :floor_tiles, map: ROOM).scroll_to 2, 1
      background(:walls, tiles: :wall_tiles, map: ROOM).scroll_to 5, 3
      status_bar :score, tiles: :bar_tiles, map: ROOM.first(4), top: 0
      size = var :size, 1
      game_loop do
        size.approach! 16, 1
        pixelate size, sprites: false
      end
    end
    b.finalize_program
    (2..9).each do |frames|
      run = game_player.run(b.program, frames: frames)
      size = run[:size]
      room_spots.each do |x, y|
        assert_equal run.screen.pixel(x - (x % size), y - (y % size)), run.screen.pixel(x, y),
                     "frame #{frames}, blocks of #{size}: (#{x}, #{y})"
      end
    end
  end

  # A painted screen is one picture, and all of it is in blocks.
  def test_a_painted_screen_is_in_blocks
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      9.times { |i| fill_rect 3 + (i * 25), 5 + (i * 13), 14, 9, %i[red green blue][i % 3] }
      12.times { |i| pixel 7 + (i * 19), 150 - (i * 11), :white }
      game_loop { pixelate 5, sprites: false }
    end
    b.finalize_program
    screen = game_player.run(b.program, frames: 3).screen
    spots = (0...200).step(7).flat_map { |x| (0...150).step(4).map { |y| [x, y] } }

    spots.each { |x, y| assert_equal screen.pixel(x - (x % 5), y - (y % 5)), screen.pixel(x, y), "(#{x}, #{y})" }
    assert_operator spots.map { |x, y| screen.pixel(x, y) }.uniq.size, :>, 2
  end

  # ...and the hero is drawn as it is with no blocks at all, every pixel of it, on every frame.
  def test_the_sprite_is_left_as_drawn
    in_blocks = fading_room(blocks: true)
    sharp = fading_room(blocks: false)
    hero_spots = (0...HERO_SIZE).flat_map { |dx| (0...HERO_SIZE).map { |dy| [HERO[0] + dx, HERO[1] + dy] } }
                                .reject { |x, y| PATCH.lines[y - HERO[1]][x - HERO[0]] == "." }
    [3, 8, 13].each do |frames|
      blocky = game_player.run(in_blocks, frames: frames).screen
      drawn = game_player.run(sharp, frames: frames).screen

      assert_equal(hero_spots.map { |x, y| drawn.pixel(x, y) }, hero_spots.map { |x, y| blocky.pixel(x, y) },
                   "frame #{frames}: the hero is as drawn")
    end
  end
end
