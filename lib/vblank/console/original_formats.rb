# frozen_string_literal: true

module VBlank
  module Console
    # HOW A CONSOLE'S GAMES KEEP THEIR TILES, COLOURS AND NUMBERS IN THE CARTRIDGE, as plain numbers.
    # A port of a game for that console reads the original's data in these layouts (a slot of a
    # data pack, Original::Slot), and the pack holds the bytes as the original keeps them. Each
    # console's layouts are in its hardware file, and its kit names them (Kit#original_formats).
    #
    # Every layout here is described, not coded: one reader (IR::FormatReading, and
    # rg_start_file_fill_picture in each runtime) reads any of them from these numbers. So a console
    # added brings its numbers and nothing else.

    # AN 8x8 TILE: where each bit of each pixel is. Bits are counted through the tile's bytes, eight
    # to a byte, bit 0 the lowest of the first byte. Bit +p+ of the pixel at column +x+ and row +y+
    # is bit number plane_bits[p] + (y * row_bits) + column_bits[x]. So +plane_bits+ has one entry
    # for each bit a pixel has, and a tile has 2 ** that many colours.
    #
    #   the Advance's (two pixels a byte, the left one in the low half):
    #     plane_bits [0, 1, 2, 3], row_bits 32, column_bits [0, 4, 8, ... 28]
    #   a tile kept in bit planes (the Color's: a row's plane 0 in one byte, then plane 1), the
    #   leftmost pixel in a byte's top bit:
    #     plane_bits [0, 8], row_bits 16, column_bits [7, 6, ... 0]
    TileFormat = Data.define(:plane_bits, :row_bits, :column_bits) do
      def colors = 1 << plane_bits.length
      def tile_bytes = plane_bits.length * 8
    end

    # A COLOUR in two bytes: whether the high byte is first, and the lowest bit of each channel
    # in the two bytes read as one number, each +channel_bits+ wide (3 to 5). A channel narrower than
    # five bits is widened to five as the console shows it (its bits repeated, so the brightest is 31).
    ColorFormat = Data.define(:high_byte_first, :red_at, :green_at, :blue_at, :channel_bits)

    # A NUMBER of one, two or four bytes: whether the high byte is first.
    NumberFormat = Data.define(:high_byte_first)

    # A CELL OF A BACKGROUND'S MAP, one number of +cell_bytes+ bytes, two unless it says: which tile
    # (+tile_bits+ wide from bit 0), whether it is mirrored left to right and upside down (the bits
    # +mirror_bit+ and +flip_bit+, nil for a cell that cannot turn its tile), and which bank of
    # colours it is drawn from (+bank_bits+ wide from bit +bank_at+; no bits for a cell whose tiles
    # all draw from one bank, the first). A bit the console keeps for itself, like the Super
    # Nintendo's priority, is not read: a background's layer says where it is drawn.
    #
    # A cell bigger than a tile is the tiles a block of video memory holds, +row_tiles+ tiles to a
    # row of it: a 16x16 cell at tile t is tiles t, t + 1, t + row_tiles and t + row_tiles + 1. Nil
    # for a console whose cells are one tile each.
    MapWordFormat = Data.define(:tile_bits, :mirror_bit, :flip_bit, :bank_at, :bank_bits, :row_tiles, :cell_bytes) do
      def initialize(tile_bits:, mirror_bit:, flip_bit:, bank_at:, bank_bits:, row_tiles:, cell_bytes: 2) = super

      def tile_of(word) = word & ((1 << tile_bits) - 1)
      def mirrored?(word) = !mirror_bit.nil? && word[mirror_bit] == 1
      def flipped?(word) = !flip_bit.nil? && word[flip_bit] == 1
      def bank_of(word) = (word >> bank_at) & ((1 << bank_bits) - 1)

      # How wide a slot of numbers that holds such cells is: :byte or :half.
      def cell_width = cell_bytes == 1 ? :byte : :half

      # The highest number a cell can be.
      def most_cell = (1 << (cell_bytes * 8)) - 1

      # A bit of the cell that is never set, for a reader that is handed a bit for each turn
      # and has no way to be told a cell has none (each runtime's rg_start_file_fill_background):
      # the one past the cell's last.
      def unset_bit = cell_bytes * 8

      # The bits of a cell that are read: its tile, its turn and its bank of colours. Two cells
      # that differ only in a bit outside these are drawn alike.
      def read_bits
        turns = [mirror_bit, flip_bit].compact.sum { |bit| 1 << bit }
        ((1 << tile_bits) - 1) | turns | (((1 << bank_bits) - 1) << bank_at)
      end

      # The tile drawn at +along+ and +down+ (in tiles, from the cell's top left as drawn) of the
      # cell +word+ stands for, a cell +side+ tiles square. A cell turned over turns each of its
      # tiles and swaps them about, as the console turns the whole cell. The build reads a map so,
      # the interpreter reads one from a file so (IR::StartFile), and each runtime for a computer
      # does the same sum (rg_start_file_fill_background).
      def cell_tile(word, along, down, side)
        mirrored = mirrored?(word)
        upside_down = flipped?(word)
        from_along = mirrored ? side - 1 - along : along
        from_down = upside_down ? side - 1 - down : down
        CellTile.new(tile: tile_of(word) + (from_down * (row_tiles || 0)) + from_along, bank: bank_of(word),
                     mirrored: mirrored, upside_down: upside_down)
      end
    end

    # ONE TILE OF A CELL, as it is drawn: which tile of video memory, turned how, from which bank
    # of colours (MapWordFormat#cell_tile).
    CellTile = Data.define(:tile, :bank, :mirrored, :upside_down) do
      # The ways it is turned, as a picture names a turn (IR::Assets::Image#turned).
      def turns = [(:mirrored if mirrored), (:upside_down if upside_down)].compact
    end

    # Everything one console keeps in its own layout: the kinds of tile it keeps (a list of
    # TileFormat, one for each number of colours), its colours, its numbers, and the cells of its
    # backgrounds' maps (a MapWordFormat, or nil for a console whose map is not one number a cell).
    OriginalFormats = Data.define(:tiles, :colors, :numbers, :map_words) do
      def initialize(tiles:, colors:, numbers:, map_words: nil) = super

      # The kind of tile of +colors+ colours, or nil.
      def tiles_of(colors) = tiles.find { |format| format.colors == colors }
    end

    # The two layouts of a tile most consoles share.
    # Two pixels a byte, the left in the low half.
    LOW_HALF_FIRST_TILES = TileFormat.new(plane_bits: [0, 1, 2, 3], row_bits: 32, column_bits: (0...8).map { |x| x * 4 })
    # Two bit planes, a row's plane 0 then plane 1, the left pixel in a byte's top bit.
    TWO_PLANE_TILES = TileFormat.new(plane_bits: [0, 8], row_bits: 16,
                                     column_bits: (0...8).map { |x| 7 - x })
    # A BYTE A PIXEL, row by row: a tile of 256 colours, 64 bytes, each byte a place in the whole
    # table of colours. It is how a layer that turns and resizes keeps its pictures, since the
    # console reads one of its pixels at a time and never a row of them: the Advance's turning
    # layer, and the Super Nintendo's Mode 7. A byte is a byte in every layout, so a slot of
    # tiles of 256 colours is kept this way whatever console the original is for.
    BYTE_A_PIXEL_TILES = TileFormat.new(plane_bits: (0...8).to_a, row_bits: 64, column_bits: (0...8).map { |x| x * 8 })
    # A BYTE A CELL: the map of such a layer. The byte is the tile's number and nothing else,
    # with no bit to turn the tile and none to pick a bank, so every tile draws from the first.
    BYTE_MAP_CELLS = MapWordFormat.new(tile_bits: 8, mirror_bit: nil, flip_bit: nil, bank_at: 0, bank_bits: 0,
                                       row_tiles: nil, cell_bytes: 1)
    # Fifteen bits, five a channel, red lowest, low byte first.
    FIFTEEN_BIT_COLORS = ColorFormat.new(high_byte_first: false,
                                         red_at: 0, green_at: 5, blue_at: 10, channel_bits: 5)
    LOW_BYTE_FIRST_NUMBERS = NumberFormat.new(high_byte_first: false)
    HIGH_BYTE_FIRST_NUMBERS = NumberFormat.new(high_byte_first: true)
    [LOW_HALF_FIRST_TILES, TWO_PLANE_TILES, BYTE_A_PIXEL_TILES, BYTE_MAP_CELLS, FIFTEEN_BIT_COLORS, LOW_BYTE_FIRST_NUMBERS,
     HIGH_BYTE_FIRST_NUMBERS].each do |format|
      Ractor.make_shareable(format)
    end
  end
end
