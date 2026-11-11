# frozen_string_literal: true

require "digest"
require "tmpdir"
require "pack_turning_background_games"

# A MADE-UP ORIGINAL THAT KEEPS ONE STRETCH OF VIDEO MEMORY, as a console does: tiles of sixteen
# colours, then the map of a layer that turns, one byte a cell, then that layer's tiles, a byte a
# pixel. A game reads the stretch as ONE slot of sixteen-colour tiles and takes the map and the
# byte tiles through views of it (DSL::PackSlot#as_numbers, #as_tiles). The answer key is the
# same game with a slot of its own for each part, which is how a game read them before a slot had
# views. The turning layer's data is PackTurningBackgroundGames'.
module PackSlotViewGames
  TABLE = PackTurningBackgroundGames::TABLE
  BYTE_TILES = PackTurningBackgroundGames::BYTE_TILES
  CELLS = PackTurningBackgroundGames::CELLS
  SIDE = PackTurningBackgroundGames::SIDE
  PIVOT = PackTurningBackgroundGames::PIVOT
  MIDDLE = PackTurningBackgroundGames::MIDDLE

  # Tiles of sixteen colours. Tile 0 draws nothing, and each other has see-through pixels, so the
  # layer behind shows through the ground.
  GROUND_TILES = [
    Array.new(64, 0),
    (0...64).map { |at| ((at % 8) + (at / 8)).even? ? 0 : 1 + (((at % 8) + (3 * (at / 8))) % 15) },
    (0...64).map { |at| (at / 8) < 4 ? 0 : 15 - ((at % 8) + (at / 8)) },
    (0...64).map { |at| at % 8 < 3 ? 9 + (at % 5) : 0 }
  ].freeze
  # The Advance keeps such a tile two pixels a byte, the left one in the low half.
  GROUND_BYTES = GROUND_TILES.map { |places| places.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*") }.join.freeze
  # The ground's map, a cell of two bytes each as the Advance keeps one: tile in bits 0 to 9,
  # mirrored 10, upside down 11, bank 12 to 15.
  GROUND_ACROSS = 8
  GROUND_WORDS = Array.new(GROUND_ACROSS * 4) do |at|
    tile = ((at * 3) + (at / GROUND_ACROSS)) % 5
    tile = 0 if tile > 3
    tile | (at.odd? ? 1 << 10 : 0) | ((at % 3).zero? ? 1 << 11 : 0) | ((at % 4) << 12)
  end.freeze

  COLORS_AT = 0x40
  GROUND_MAP_AT = COLORS_AT + (TABLE.length * 2)
  VIDEO_AT = GROUND_MAP_AT + (GROUND_WORDS.length * 2)
  # Where each part is in the video stretch, in bytes from its start.
  CELLS_IN_VIDEO = GROUND_BYTES.bytesize
  PICTURES_IN_VIDEO = CELLS_IN_VIDEO + CELLS.length
  VIDEO_BYTES = PICTURES_IN_VIDEO + (BYTE_TILES.length * 64)
  # How many bytes one sixteen-colour tile of the Advance is.
  GROUND_TILE_BYTES = 32

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def slot_view_original(folder)
    copy = "\0".b * (VIDEO_AT + VIDEO_BYTES)
    copy[COLORS_AT, TABLE.length * 2] = TABLE.pack("v*")
    copy[GROUND_MAP_AT, GROUND_WORDS.length * 2] = GROUND_WORDS.pack("v*")
    copy[VIDEO_AT, VIDEO_BYTES] = GROUND_BYTES + CELLS.pack("C*") + BYTE_TILES.flatten.pack("C*")
    path = File.join(folder, "made_up_video.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The pack of a game that reads the stretch as one slot (+views+), or as a slot for each part.
  # Run on the builder. Hands back the pack, the ground's tiles, the layer's tiles and its map.
  def self.declare_video(builder, from, views:)
    pack = builder.data_pack from: from, version: "1" do |slots|
      if views
        slots.tiles :video, at: VIDEO_AT, count: VIDEO_BYTES / GROUND_TILE_BYTES, colors: 16
      else
        slots.tiles :ground_tiles, at: VIDEO_AT, count: GROUND_TILES.length, colors: 16
        slots.numbers :cells, at: VIDEO_AT + CELLS_IN_VIDEO, count: CELLS.length, width: :byte, signed: false
        slots.tiles :pictures, at: VIDEO_AT + PICTURES_IN_VIDEO, count: BYTE_TILES.length, colors: 256
      end
      slots.numbers :ground_map, at: GROUND_MAP_AT, count: GROUND_WORDS.length, width: :half, signed: false
      slots.colors :table, at: COLORS_AT, count: TABLE.length
    end
    return [pack, pack[:ground_tiles], pack[:pictures], pack[:cells]] unless views

    video = pack[:video]
    # The byte tiles reach the slot's end, so their count is left out.
    [pack, video, video.as_tiles(at: PICTURES_IN_VIDEO, colors: 256),
     video.as_numbers(at: CELLS_IN_VIDEO, count: CELLS.length, width: :byte, signed: false)]
  end

  # A GAME OF TWO BACKGROUNDS FROM THE ONE STRETCH: a layer that turns, behind a ground of
  # sixteen-colour tiles with holes in it. The block is handed the layer. Hands back the program
  # and the pack file the build made (nil for a build that leaves its pack out).
  private def two_shapes_game_and_file(from, views:, options: VBlank::Cartridge::Options.new, &more)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack, ground_tiles, pictures, cells = PackSlotViewGames.declare_video(self, from, views: views)
      layer = background :layer, tiles: pictures, map: cells, colors: pack[:table], across: SIDE
      background :ground, tiles: ground_tiles, map: pack[:ground_map], colors: pack[:table], across: GROUND_ACROSS
      instance_exec(layer, &more)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # A GAME ANY CONSOLE PLAYS, reading the stretch in two more shapes: a tile of the layer as a
  # picture of pixels, and its first bytes as a table of numbers, signed and not, which place a
  # mark each pass.
  private def table_and_pixels_game_and_file(from, views:, options: VBlank::Cartridge::Options.new)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      pack, = PackSlotViewGames.declare_video(self, from, views: views)
      if views
        art = pack[:video].as_pixels(at: PICTURES_IN_VIDEO + 64, count: 64)
        plain = pack[:video].as_numbers(at: PICTURES_IN_VIDEO + 64, count: 8, width: :byte, signed: false)
        signed = pack[:video].as_numbers(at: PICTURES_IN_VIDEO + 64, count: 8, width: :byte, signed: true)
        image :art, width: 8, height: 8, colors: TABLE, places: art
        steps = table :steps, plain
        drops = table :drops, signed
      else
        # The answer key holds what the stretch holds there, written in the game.
        image :art, width: 8, height: 8, data: BYTE_TILES[1].map { |place| TABLE[place] }
        steps = table :steps, BYTE_TILES[1].first(8)
        drops = table :drops, BYTE_TILES[1].first(8).map { |byte| byte - 256 }
      end
      pass = var :pass, 0
      game_loop do
        clear_screen :black
        blit :art, 20, 20
        draw_rect_at steps[pass], 60, 4, 4, :white
        draw_rect_at drops[pass] + 100, 80, 4, 4, :red
        pass = (pass + 1) & 7
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end
end
