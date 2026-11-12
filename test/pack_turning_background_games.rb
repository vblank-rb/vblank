# frozen_string_literal: true

require "digest"
require "tmpdir"

# A MADE-UP ORIGINAL WHOSE SCREEN IS A LAYER THAT TURNS AND RESIZES, kept as a console keeps one:
# a map of one byte a cell, each the number of a tile and nothing else, over tiles of a byte a
# pixel, each byte a place in one table of 256 colours. A game shows it through a data pack
# (Builder::PackBackgrounds), and the SAME background is made beside it from pictures the game
# draws itself, which is the answer key: the same pixels, declared two ways. The made-up data is
# written here and read by no reader of VBlank's.
module PackTurningBackgroundGames
  # 256 colours, each unlike every other.
  TABLE = Array.new(256) { |at| ((at * 131) + 7) & 0x7FFF }.freeze
  # Tiles of a byte a pixel. Tile 0 draws nothing. The others pick from both ends of the table,
  # so a tile read four bits a pixel shows other colours, and no row or column of one reads the
  # same both ways.
  BYTE_TILES = [
    Array.new(64, 0),
    (0...64).map { |at| 200 + (((at % 8) + (3 * (at / 8))) % 5) },
    (0...64).map { |at| (at % 8) < (at / 8) ? 0 : 250 + (at % 3) }, # see-through below its diagonal
    (0...64).map { |at| 1 + ((at / 8) % 4) + (at % 8 > 4 ? 16 : 0) },
    (0...64).map { |at| (at % 3).zero? ? 255 : 128 }
  ].freeze
  SIDE = 32
  # The map, no row or column of it alike, with empty cells among the tiles.
  CELLS = Array.new(SIDE * SIDE) do |at|
    tile = ((3 * (at % SIDE)) + (5 * (at / SIDE))) % 7
    tile < BYTE_TILES.length ? tile : 0
  end.freeze

  COLORS_AT = 0x40
  MAP_AT = COLORS_AT + (TABLE.length * 2)
  TILES_AT = MAP_AT + CELLS.length
  COPY_SIZE = TILES_AT + (BYTE_TILES.length * 64)
  # A point of the screen, and the map's own middle.
  PIVOT = [100, 60].freeze
  MIDDLE = [128, 128].freeze

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # The made-up original, for +platform+: the table, the map and the tiles, each as its bytes.
  private def turning_original(folder, platform: :gba)
    copy = "\0".b * COPY_SIZE
    copy[COLORS_AT, TABLE.length * 2] = TABLE.pack("v*")
    copy[MAP_AT, CELLS.length] = CELLS.pack("C*")
    copy[TILES_AT, BYTE_TILES.length * 64] = BYTE_TILES.flatten.pack("C*")
    path = File.join(folder, "made_up_turning.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing the layer from the pack, and whatever the block does with its handle. Hands back
  # the program and the pack file the build made (nil for a build that leaves its pack out).
  # +from_runs+ takes the map as a run of a bigger slot and the tiles from a tile of theirs on.
  private def turning_pack_game_and_file(from, options: VBlank::Cartridge::Options.new, from_runs: false, &more)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        if from_runs
          slots.tiles :pictures, at: TILES_AT - 64, count: BYTE_TILES.length + 1, colors: 256
          slots.numbers :cells, at: MAP_AT - 16, count: CELLS.length + 16, width: :byte, signed: false
        else
          slots.tiles :pictures, at: TILES_AT, count: BYTE_TILES.length, colors: 256
          slots.numbers :cells, at: MAP_AT, count: CELLS.length, width: :byte, signed: false
        end
        slots.colors :table, at: COLORS_AT, count: TABLE.length
      end
      pictures = from_runs ? pack[:pictures].tile(1) : pack[:pictures]
      cells = from_runs ? pack[:cells].numbers(16, CELLS.length) : pack[:cells]
      layer = background :layer, tiles: pictures, map: cells, colors: pack[:table], across: SIDE
      instance_exec(layer, &more)
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  private def turning_pack_game(...) = turning_pack_game_and_file(...).first

  # The same background from pictures the game draws itself, and the same block.
  private def turning_drawn_game(&more)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      drawn = (1...BYTE_TILES.length).to_h do |tile|
        image :"picture_#{tile}", width: 8, height: 8, transparent: true,
                                  data: BYTE_TILES[tile].map { |place| place.zero? ? :transparent : TABLE[place] }
        [tile, :"picture_#{tile}"]
      end
      tiles :pictures, drawn
      layer = background :layer, tiles: :pictures, map: CELLS.each_slice(SIDE).map { |row| row.map { |tile| tile.zero? ? nil : tile } }
      instance_exec(layer, &more)
    end
    b.finalize_program
    b.program
  end

  # What the made-up data says the map's pixel at (+x+, +y+) is: a colour, or nil where it draws nothing.
  private def turning_map_color(x, y)
    place = BYTE_TILES.fetch(CELLS.fetch(((y / 8) * SIDE) + (x / 8))).fetch(((y % 8) * 8) + (x % 8))
    place.zero? ? nil : TABLE.fetch(place)
  end
end
