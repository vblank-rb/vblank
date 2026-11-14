# frozen_string_literal: true

require "digest"
require "tmpdir"
require "pack_turning_background_games"

# A MADE-UP ADVANCE ORIGINAL WHOSE SCREEN IS A TEXT LAYER OF 256 COLOURS: more tiles than a byte
# can name, each a byte a pixel in the same one table of 256 colours, and a map of two bytes a cell
# as the Advance keeps one: the tile in bits 0 to 9, mirrored in bit 10, upside down in bit 11, and
# a bank of colours in bits 12 to 15, which the Advance does not read under tiles of 256 colours.
# The made-up map sets those bits on some cells, as an original's map may. A game shows it through
# a data pack, its unpacking writing each cell as a map cell (Original::MapCell), and the SAME
# background is made beside it from pictures the game draws itself, which is the answer key. The
# cells are decoded here from the Advance's layout, not by any reader of VBlank's.
module PackTableTileBackgroundGames
  TABLE = PackTurningBackgroundGames::TABLE
  # Where each part of the Advance's cell is.
  TILE_BITS = 0x3FF
  MIRROR_BIT = 10
  FLIP_BIT = 11
  BANK_AT = 12
  # Tile 0 draws nothing. Every other picks its own bytes, see-through at a few, and no row or
  # column of one reads the same both ways, so a turn shows.
  TILE_COUNT = 300
  TILES = Array.new(TILE_COUNT) do |tile|
    next Array.new(64, 0) if tile.zero?

    Array.new(64) { |at| ((at + tile) % 11).zero? ? 0 : 1 + (((tile * 13) + (at * 7) + ((at / 8) * 3)) % 255) }
  end.freeze
  ACROSS = 32
  DOWN = 20
  # The map: every tile, some mirrored, some upside down, some both, and a bank among the bits.
  WORDS = Array.new(ACROSS * DOWN) do |at|
    tile = (at * 7) % TILE_COUNT
    tile | ((at % 5 == 1 ? 1 : 0) << MIRROR_BIT) | ((at % 3 == 2 ? 1 : 0) << FLIP_BIT) | ((at % 4) << BANK_AT)
  end.freeze

  COLORS_AT = 0x40
  MAP_AT = COLORS_AT + (TABLE.length * 2)
  TILES_AT = MAP_AT + (WORDS.length * 2)
  COPY_SIZE = TILES_AT + (TILES.length * 64)

  # One cell of the made-up map, decoded from the Advance's layout.
  Cell = Data.define(:tile, :mirrored, :upside_down)

  def self.cell_of(word) = Cell.new(tile: word & TILE_BITS, mirrored: word[MIRROR_BIT] == 1, upside_down: word[FLIP_BIT] == 1)

  # How the made-up map reaches the background: :map_cells the unpacking writes with bank 0, as a
  # port does; :banked_map_cells, the same with each cell's bank bits written as its bank; or
  # :two_byte_cells, the original's map read as it is.
  MAPS = %i[map_cells banked_map_cells two_byte_cells].freeze

  VBlank::Testing::InRactors.share_constants(self)

  private def table_tile_original(folder)
    copy = "\0".b * COPY_SIZE
    copy[COLORS_AT, TABLE.length * 2] = TABLE.pack("v*")
    copy[MAP_AT, WORDS.length * 2] = WORDS.pack("v*")
    copy[TILES_AT, TILES.length * 64] = TILES.flatten.pack("C*")
    path = File.join(folder, "made_up_table_tiles.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing the screen from the pack, its map as +map+ (one of MAPS) says, and whatever the
  # block does with its handle. Hands back the program and the pack file the build made (nil for
  # a build that leaves its pack out).
  private def table_tile_pack_game_and_file(from, options: VBlank::Cartridge::Options.new, map: :map_cells, &more)
    raise ArgumentError, "map: is one of #{MAPS.inspect}" unless MAPS.include?(map)

    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :pictures, at: TILES_AT, count: TILE_COUNT, colors: 256
        slots.colors :table, at: COLORS_AT, count: TABLE.length
        next slots.numbers :cells, at: MAP_AT, count: WORDS.length, width: :half, signed: false if map == :two_byte_cells

        slots.map_cells :cells, count: WORDS.length
        slots.fill_from_copy do |copy, filled|
          repeat(WORDS.length) do |at|
            word = copy.half(MAP_AT + (at * 2))
            filled[:cells].write_cell(at, tile: word & TILE_BITS, mirrored: word >> MIRROR_BIT, upside_down: word >> FLIP_BIT,
                                          bank: map == :banked_map_cells ? word >> BANK_AT : 0)
          end
        end
      end
      layer = background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: ACROSS
      instance_exec(layer, &more)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # THE ANSWER KEY: the same screen with each cell decoded here, and written in the game as a
  # picture of 8x8 in the table's colours, turned as the cell says.
  private def table_tile_drawn_game(&more)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pictures = {}
      cells = WORDS.map do |word|
        cell = PackTableTileBackgroundGames.cell_of(word)
        next nil if TILES.fetch(cell.tile).all?(&:zero?)

        pictures.fetch(cell) do
          pixels = TILES.fetch(cell.tile).each_slice(8).to_a
          pixels = pixels.map(&:reverse) if cell.mirrored
          pixels = pixels.reverse if cell.upside_down
          name = :"cell #{pictures.length}"
          image name, width: 8, height: 8, transparent: true,
                      data: pixels.flatten.map { |place| place.zero? ? :transparent : TABLE.fetch(place) }
          pictures[cell] = name
        end
      end
      tiles :by_hand, pictures.values.to_h { |name| [name, name] }
      layer = background :layer, tiles: :by_hand, map: cells.each_slice(ACROSS).to_a
      instance_exec(layer, &more)
    end
    b.finalize_program
    b.program
  end
end
