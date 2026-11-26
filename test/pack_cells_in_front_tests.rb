# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "pack_background_tests"

# Cells of a background from the data pack drawn in front of the sprites (`cells_in_front: true`,
# Builder::PackBackgrounds#mark_tiles_in_front). A Genesis original marks a cell of its map for in
# front with the cell's top bit, its priority, and a sprite passing under such a cell is hidden by
# the cell's drawn pixels and shows through its see-through ones, as the console draws it. A port
# that writes map cells of VBlank's own marks one with `write_cell(..., in_front:)`.
#
# The answer key is the made-up map itself: each cell names its tile and whether it is in front,
# written here from the Genesis's hardware, and a sprite of one colour is placed over four cells
# at once, so every pixel under it is the tile's colour or the sprite's by that rule alone.
module PackCellsInFrontGames
  include PackBackgroundGames

  # A cell of the Genesis's map: the tile in bits 0 to 10, and its priority in bit 15.
  GENESIS_FRONT_CELL = ->(tile, front) { tile | (front ? 1 << 15 : 0) }

  # Two rows of four cells, each [tile, in front]. Tile 0 draws nothing, and tiles 1 to 3 have
  # see-through places among their drawn ones (places).
  CELLS = [[1, true], [1, false], [3, true], [2, false],
           [0, true], [2, true], [1, false], [3, false]].freeze
  ACROSS = 4
  # The bytes the map-cell game's unpacking reads: each cell's tile, and its mark, a byte each.
  CELL_TILES_AT = 0x80
  CELL_MARKS_AT = 0x90

  # The cell the game writes on its second pass when told to: the second cell, behind, becomes tile 3
  # in front, as an original writes a cell whole, its priority with it.
  WRITTEN_AT = 1
  WRITTEN = [3, true].freeze
  WRITTEN_PASS = 2

  # The sprite: one colour all over, 8x8, placed over the corner the first four cells share.
  SPRITE_COLOR = MadeUpOriginalLayouts::PALETTE[9]
  SPRITE_AT = [4, 4].freeze
  SPRITE_SIDE = 8

  # A sprite in front (`in_front: true`), declared before the walker so only its mark puts it in
  # front: a checkerboard of its own colour and see-through places, over the same cells as the walker.
  POINTER_COLOR = MadeUpOriginalLayouts::PALETTE[12]
  POINTER_PLACES = Array.new(SPRITE_SIDE * SPRITE_SIDE) { |at| ((at % 8) + (at / 8)).even? }.freeze

  # A second sprite in front, of one colour all over, over the same cells: the pointer and it take
  # turns in front of each other a frame each (`draw_in_order ..., take_turns: true`), and whichever
  # is in front is over the cells in front as well.
  HAND_COLOR = MadeUpOriginalLayouts::PALETTE[14]

  # A second area, for a background walking between areas: the same cells, each mark the other way.
  FAR_CELLS = CELLS.map { |tile, front| [tile, !front] }.freeze
  # The passes the walking game (#front_areas_game_and_file) writes WRITTEN in the first area on,
  # walks to the second on, and writes WRITTEN there on.
  NEAR_WRITTEN_PASS = 4
  FAR_WALK_PASS = 7
  FAR_WRITTEN_PASS = 10

  VBlank::Testing::InRactors.share_constants(self)

  # The game walking between two areas (`map:` a Hash by area) marking cells in front: :near is
  # CELLS and :far FAR_CELLS, each a slot of map cells the unpacking writes, both over the one slot
  # of tiles, or with +own_tiles+ each area over a slot of its own holding the same tiles. Told
  # WRITTEN by a slot of one place (`set_cells: pack[:changes]`), it writes it at WRITTEN_AT in each
  # area, on NEAR_WRITTEN_PASS and FAR_WRITTEN_PASS, and walks to :far on FAR_WALK_PASS. The walker
  # is under the cells, at SPRITE_AT. Hands back the program and the pack file the build made.
  private def front_areas_game_and_file(folder, own_tiles: false, options: VBlank::Cartridge::Options.new)
    from = front_original(folder)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: PLACES.length, colors: 16
        slots.tiles :far_video, at: TILES_AT, count: PLACES.length, colors: 16 if own_tiles
        slots.colors :palette, at: COLORS_AT, count: 32
        slots.map_cells :near_map, count: CELLS.length
        slots.map_cells :far_map, count: CELLS.length
        slots.map_cells :changes, count: 1
        slots.fill_from_copy do |_copy, filled|
          { near_map: CELLS, far_map: FAR_CELLS, changes: [WRITTEN] }.each do |slot, cells|
            cells.each_with_index { |(tile, front), at| filled[slot].write_cell(at, tile: tile, in_front: front) }
          end
        end
      end
      machine = background :machine, tiles: { near: pack[:video], far: pack[own_tiles ? :far_video : :video] },
                                     map: { near: pack[:near_map], far: pack[:far_map] }, colors: pack[:palette],
                                     across: ACROSS, cells_in_front: true, set_cells: pack[:changes]
      image :walker, width: SPRITE_SIDE, height: SPRITE_SIDE, data: Array.new(SPRITE_SIDE * SPRITE_SIDE, SPRITE_COLOR)
      sprite :walker, at: SPRITE_AT
      passes = var :passes, 0
      game_loop do
        passes.store!(passes + 1)
        machine.set_cell WRITTEN_AT % ACROSS, WRITTEN_AT / ACROSS, 0 if passes == NEAR_WRITTEN_PASS
        machine.show_map :far if passes == FAR_WALK_PASS
        machine.set_cell WRITTEN_AT % ACROSS, WRITTEN_AT / ACROSS, 0 if passes == FAR_WRITTEN_PASS
        wait_vblank
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # +cells+ with WRITTEN at WRITTEN_AT.
  private def with_written(cells) = cells.dup.tap { |written| written[WRITTEN_AT] = WRITTEN }

  # The game of two sprites in front taking turns: the pointer and the hand, each of one colour all
  # over and both in front, at SPRITE_AT over the original's map with its cells in front, put in
  # order with `take_turns:` given +take_turns+.
  private def turns_game(folder, take_turns: true)
    from = front_original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: PLACES.length, colors: 16
        slots.colors :palette, at: COLORS_AT, count: 32
        slots.numbers :map, at: MAP_AT, count: CELLS.length, width: :half, signed: false
      end
      background :machine, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS,
                           cells_in_front: true
      image :pointer, width: SPRITE_SIDE, height: SPRITE_SIDE, data: Array.new(SPRITE_SIDE * SPRITE_SIDE, POINTER_COLOR)
      image :hand, width: SPRITE_SIDE, height: SPRITE_SIDE, data: Array.new(SPRITE_SIDE * SPRITE_SIDE, HAND_COLOR)
      pointer = sprite :pointer, at: SPRITE_AT, in_front: true
      hand = sprite :hand, at: SPRITE_AT, in_front: true
      draw_in_order pointer, hand, take_turns: take_turns
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Every pixel under the sprites at SPRITE_AT, as [x, y].
  private def spots_under_sprites
    left, top = SPRITE_AT
    (top...(top + SPRITE_SIDE)).flat_map { |y| (left...(left + SPRITE_SIDE)).map { |x| [x, y] } }
  end

  # The made-up Genesis original: CELLS as its map at MAP_AT, its two banks at COLORS_AT, PLACES as
  # its tiles at TILES_AT, and each cell's tile and mark as bytes, for a port that writes map cells.
  private def front_original(folder)
    tiles = PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    levels = MadeUpOriginalLayouts::LEVELS
    copy[COLORS_AT, 64] = GENESIS_COLORS.(levels + levels.rotate(7))
    copy[MAP_AT, CELLS.length * 2] = CELLS.map { |tile, front| GENESIS_FRONT_CELL.(tile, front) }.pack("n*")
    copy[CELL_TILES_AT, CELLS.length] = CELLS.map(&:first).pack("C*")
    copy[CELL_MARKS_AT, CELLS.length] = CELLS.map { |_, front| front ? 1 : 0 }.pack("C*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up_front.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game: the original's map as a background that reads its cells' marks, and the sprite over
  # it. +map+ is :console for the Genesis's own cells, or :map_cells for map cells the unpacking
  # writes. +cells_in_front+ is what the background is given. With +written+, the background is
  # told WRITTEN and writes it at WRITTEN_AT on pass WRITTEN_PASS. With +pointer+ a sprite in front
  # (POINTER_PLACES) is over the walker. Hands back the program and the pack file the build made
  # (nil with the pack left out).
  private def front_game_and_file(folder, map: :console, cells_in_front: true, written: false, pointer: false,
                                  options: VBlank::Cartridge::Options.new)
    from = front_original(folder)
    tile, front = WRITTEN
    word = map == :console ? GENESIS_FRONT_CELL.(tile, front) : VBlank::Original::MapCell.number(tile: tile, in_front: front)
    told = written ? { set_cells: [word] } : {}
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: PLACES.length, colors: 16
        slots.colors :palette, at: COLORS_AT, count: 32
        if map == :console
          slots.numbers :map, at: MAP_AT, count: CELLS.length, width: :half, signed: false
        else
          slots.map_cells :map, count: CELLS.length
          slots.fill_from_copy do |copy, filled|
            repeat(CELLS.length) do |at|
              filled[:map].write_cell(at, tile: copy.byte(CELL_TILES_AT + at), in_front: copy.byte(CELL_MARKS_AT + at))
            end
          end
        end
      end
      machine = background :machine, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS,
                                     cells_in_front: cells_in_front, **told
      if pointer
        image(:pointer, "#" => POINTER_COLOR, "." => :transparent) do
          POINTER_PLACES.each_slice(SPRITE_SIDE).map { |row| row.map { |drawn| drawn ? "#" : "." }.join }.join("\n")
        end
        sprite :pointer, at: SPRITE_AT, in_front: true
      end
      image :walker, width: SPRITE_SIDE, height: SPRITE_SIDE, data: Array.new(SPRITE_SIDE * SPRITE_SIDE, SPRITE_COLOR)
      sprite :walker, at: SPRITE_AT
      passes = var :passes, 0
      game_loop do
        machine.set_cell WRITTEN_AT % ACROSS, WRITTEN_AT / ACROSS, word if written && passes == WRITTEN_PASS
        passes.store!(passes + 1)
        wait_vblank
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  private def front_game(folder, **) = front_game_and_file(folder, **).first

  # The answer key for the pixel at (+x+, +y+), inside the first two rows of cells: a cell's drawn
  # place in bank 0's colour where the cell is in front or no sprite is over it, the sprite's colour
  # where it is over a see-through place or a cell behind it, and nil (whatever is behind) where
  # neither draws.
  private def wanted_pixel(x, y, fronts: true, cells: CELLS, pointer: false)
    tile, front = cells.fetch(((y / 8) * ACROSS) + (x / 8))
    place = PLACES.fetch(tile).fetch(((y % 8) * 8) + (x % 8))
    left, top = SPRITE_AT
    under = x.between?(left, left + SPRITE_SIDE - 1) && y.between?(top, top + SPRITE_SIDE - 1)
    drawn = BANKS.fetch(0).fetch(place) unless place.zero?
    return drawn unless under
    return POINTER_COLOR if pointer && POINTER_PLACES.fetch(((y - top) * SPRITE_SIDE) + (x - left))
    return drawn if drawn && front && fronts

    SPRITE_COLOR
  end

  # Every pixel of the cells the sprite is over, and the cells beside them, as [x, y] => wanted.
  private def wanted_pixels(fronts: true, cells: CELLS, pointer: false)
    (0...16).flat_map do |y|
      (0...24).map { |x| [[x, y], wanted_pixel(x, y, fronts: fronts, cells: cells, pointer: pointer)] }
    end.to_h.compact
  end

  # CELLS with WRITTEN at WRITTEN_AT.
  private def cells_written = CELLS.dup.tap { |cells| cells[WRITTEN_AT] = WRITTEN }

  private def shown_pixels(screen, wanted) = wanted.keys.to_h { |x, y| [[x, y], screen.pixel(x, y)] }
end

# Played on each console whose build draws a cell in front of the sprites.
module PackCellsInFrontTests
  include PackCellsInFrontGames

  def test_a_sprite_is_hidden_by_the_drawn_pixels_of_cells_the_genesis_map_marks_in_front
    Dir.mktmpdir do |folder|
      screen = game_player.run(front_game(folder), frames: 3).screen
      wanted = wanted_pixels

      assert_equal wanted, shown_pixels(screen, wanted)
    end
  end

  def test_a_sprite_is_hidden_by_map_cells_written_in_front
    Dir.mktmpdir do |folder|
      screen = game_player.run(front_game(folder, map: :map_cells), frames: 3).screen
      wanted = wanted_pixels

      assert_equal wanted, shown_pixels(screen, wanted)
    end
  end

  # A cell written whole brings its mark with it: the cell behind the sprite becomes one in front.
  def test_a_cell_written_in_front_hides_the_sprite
    Dir.mktmpdir do |folder|
      %i[console map_cells].each do |map|
        screen = game_player.run(front_game(folder, map: map, written: true), frames: WRITTEN_PASS + 3).screen
        wanted = wanted_pixels(cells: cells_written)

        assert_equal wanted, shown_pixels(screen, wanted), "a cell written on a map of #{map}"
      end
    end
  end

  # A background walking between areas marks each area's cells in front, and a cell a slot told it,
  # written in each area, brings its mark: over one slot of tiles, or a slot an area.
  def test_cells_in_front_follow_the_area_showing_and_the_cells_written_there
    Dir.mktmpdir do |folder|
      [false, true].each do |own_tiles|
        program, = front_areas_game_and_file(folder, own_tiles: own_tiles)
        tiles = own_tiles ? "a slot of tiles an area" : "one slot of tiles"
        { NEAR_WRITTEN_PASS - 1 => [CELLS, "the first area"],
          NEAR_WRITTEN_PASS + 2 => [with_written(CELLS), "the first area, a cell written"],
          FAR_WALK_PASS + 2 => [FAR_CELLS, "the second area"],
          FAR_WRITTEN_PASS + 2 => [with_written(FAR_CELLS), "the second area, a cell written"] }.each do |frames, (cells, what)|
          screen = game_player.run(program, frames: frames).screen
          wanted = wanted_pixels(cells: cells)

          assert_equal wanted, shown_pixels(screen, wanted), "#{what}, over #{tiles}"
        end
      end
    end
  end

  # A background that does not ask draws every cell behind the sprites, whatever its map marks.
  def test_a_background_not_told_cells_in_front_draws_every_cell_behind_the_sprites
    Dir.mktmpdir do |folder|
      screen = game_player.run(front_game(folder, cells_in_front: nil), frames: 3).screen
      wanted = wanted_pixels(fronts: false)

      assert_equal wanted, shown_pixels(screen, wanted)
    end
  end
end

# Played on each console whose build does not draw a cell in front of the sprites: the game is
# refused in words naming the console, by the checks a build of it for that console runs (the
# interpreter's run plays any console's game, so it is asked of them by hand).
module PackCellsInFrontRefusedTests
  include PackCellsInFrontGames

  def test_cells_in_front_of_the_sprites_are_refused_naming_the_console
    Dir.mktmpdir do |folder|
      built_for_console = front_game(folder).copy.tap { |program| program.console = game_console }
      error = assert_raises(VBlank::IR::Guardrails::ValidationError) do
        VBlank::IR::ProgramChecks.findings_for!(built_for_console).raise_on_error!
      end

      assert_includes error.message, "cells_in_front: true"
      assert_includes error.message, VBlank::Console.described(game_console).title
    end
  end

  def test_a_background_not_told_cells_in_front_is_played_with_every_cell_behind_the_sprites
    Dir.mktmpdir do |folder|
      screen = game_player.run(front_game(folder, cells_in_front: nil), frames: 3).screen
      wanted = wanted_pixels(fronts: false)

      assert_equal wanted, shown_pixels(screen, wanted)
    end
  end
end

# Played on each console whose build draws a sprite told `in_front: true` over the cells in front.
module PackSpritesInFrontTests
  include PackCellsInFrontGames

  # A sprite in front is drawn over the cells in front as well as over the walker, though it was
  # declared first; through its see-through places the walker shows, or the cell in front over it.
  def test_a_sprite_in_front_is_drawn_over_the_cells_in_front
    Dir.mktmpdir do |folder|
      %i[console map_cells].each do |map|
        screen = game_player.run(front_game(folder, map: map, pointer: true), frames: 3).screen
        wanted = wanted_pixels(pointer: true)

        assert_equal wanted, shown_pixels(screen, wanted), "a map of #{map}"
      end
    end
  end

  # Two sprites in front take turns in front of each other a frame each, and each frame the one in
  # front covers every pixel under it, the cells in front's drawn pixels too.
  def test_two_sprites_in_front_take_turns_over_the_cells_in_front
    Dir.mktmpdir do |folder|
      program = turns_game(folder)
      shown = (4..7).map do |frames|
        screen = game_player.run(program, frames: frames).screen
        spots_under_sprites.map { |x, y| screen.pixel(x, y) }.uniq
      end

      shown.each { |colors| assert_equal 1, colors.length, "one sprite covers every pixel under it: #{colors.inspect}" }
      assert_includes [[POINTER_COLOR, HAND_COLOR], [HAND_COLOR, POINTER_COLOR]], shown.first(2).flatten
      assert_equal shown.first(2) * 2, shown, "the two take turns in front a frame each"
    end
  end
end

# Played on each console whose build does not draw a sprite over the cells in front: a sprite told
# `in_front: true` is refused in words naming the console.
module PackSpriteInFrontRefusedTests
  include PackCellsInFrontGames

  def test_a_sprite_in_front_is_refused_naming_the_console
    Dir.mktmpdir do |folder|
      built_for_console = front_game(folder, cells_in_front: nil, pointer: true).copy.tap { |program| program.console = game_console }
      error = assert_raises(VBlank::IR::Guardrails::ValidationError) do
        VBlank::IR::ProgramChecks.findings_for!(built_for_console).raise_on_error!
      end

      assert_includes error.message, "in_front: true"
      assert_includes error.message, VBlank::Console.described(game_console).title
    end
  end
end
