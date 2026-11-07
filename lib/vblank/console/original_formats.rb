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

    # Everything one console keeps in its own layout: the kinds of tile it keeps (a list of
    # TileFormat, one for each number of colours), its colours and its numbers.
    OriginalFormats = Data.define(:tiles, :colors, :numbers) do
      # The kind of tile of +colors+ colours, or nil.
      def tiles_of(colors) = tiles.find { |format| format.colors == colors }
    end

    # The two layouts of a tile most consoles share.
    # Two pixels a byte, the left in the low half.
    LOW_HALF_FIRST_TILES = TileFormat.new(plane_bits: [0, 1, 2, 3], row_bits: 32, column_bits: (0...8).map { |x| x * 4 })
    # Two bit planes, a row's plane 0 then plane 1, the left pixel in a byte's top bit.
    TWO_PLANE_TILES = TileFormat.new(plane_bits: [0, 8], row_bits: 16,
                                     column_bits: (0...8).map { |x| 7 - x })
    # Fifteen bits, five a channel, red lowest, low byte first.
    FIFTEEN_BIT_COLORS = ColorFormat.new(high_byte_first: false,
                                         red_at: 0, green_at: 5, blue_at: 10, channel_bits: 5)
    LOW_BYTE_FIRST_NUMBERS = NumberFormat.new(high_byte_first: false)
    [LOW_HALF_FIRST_TILES, TWO_PLANE_TILES, FIFTEEN_BIT_COLORS, LOW_BYTE_FIRST_NUMBERS].each { |format| Ractor.make_shareable(format) }
  end
end
