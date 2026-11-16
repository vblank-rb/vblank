# frozen_string_literal: true

require "digest"
require "tmpdir"

# AN ORIGINAL FROM ANOTHER CONSOLE KEEPS ITS DATA IN THAT CONSOLE'S LAYOUT, and the pack holds those
# bytes unchanged. The original names its platform (`Original::Game.new(platform: :gbc)`), and a
# slot of tiles, colours or numbers is read in that platform's layout unless it names another
# (`layout:`), which an original from a computer must.
#
# Each original here is made up: a few hundred bytes this file writes itself, encoding the same
# colours, tiles and numbers in one console's layout. The encoders below are written from each
# console's hardware, not from VBlank's readers, so they are the answer key: the same game holding
# the same colours, tiles and numbers itself must show the same picture as the one reading them
# through the pack.
module MadeUpOriginalLayouts
  # Sixteen colours whose channels are each a three-bit level widened to five (the level repeated:
  # the brightest is 31), so the Genesis's three-bit colours read back as these exactly.
  WIDEN = ->(level) { (level << 2) | (level >> 1) }
  LEVELS = (0...16).map { |at| at.zero? ? [0, 0, 0] : [(at * 3) % 8, ((at * 5) + 1) % 8, ((at * 7) + 2) % 8] }.freeze
  PALETTE = LEVELS.map { |red, green, blue| WIDEN.(red) | (WIDEN.(green) << 5) | (WIDEN.(blue) << 10) }.freeze

  # Two tiles of four colours (places 0 to 3), and two of sixteen whose places use every bit, each
  # with three colours and see-through, so each fits a Game Boy Color's background square. No row
  # reads the same both ways, so a tile read back to front differs.
  FOUR_COLOR_TILES = [(0...64).map { |at| ((at % 8) + (at / 8)) % 4 },
                      (0...64).map { |at| (at % 8) == (at / 8) ? 3 : 1 + ((at % 8) % 2) }].freeze
  SIXTEEN_COLOR_TILES = [(0...64).map { |at| [0, 3, 6, 13].fetch(((at % 8) + (2 * (at / 8))) % 4) },
                         (0...64).map { |at| [9, 10, 5, 0].fetch(((at % 8) * 3 + (at / 8)) % 4) }].freeze

  # Where the marker is drawn each frame: the low byte of each number, with a high byte that is
  # not 0, so a number read in the wrong byte order puts the marker elsewhere.
  SPEEDS = [10, 30, 50, 70, 90, 110, 130, 150].each_with_index.map { |x, at| x | ((at + 1) << 8) }.freeze

  # Signed numbers of two bytes, some below zero, which move the marker down the screen.
  OFFSETS = [-20, -10, -5, 0, 5, 10, 15, 20].freeze
  # Signed numbers of four bytes. A multiple of 0x01010101 has every byte alike except where its
  # sign changes them, so a byte swap changes the low and the high byte the marker reads.
  WORDS = (-3..4).map { |at| at * 0x01010101 }.freeze

  PALETTE_AT = 0x10
  TILES_AT = 0x40
  SPEEDS_AT = 0xA0
  OFFSETS_AT = 0xC0
  WORDS_AT = 0xD0
  COPY_SIZE = 0x100

  # The rows of a tile's places, one list of eight a row.
  ROWS = ->(places) { places.each_slice(8).to_a }
  # One bit plane of a row, the leftmost pixel in bit 7.
  PLANE = ->(row, plane) { row.each_with_index.sum { |place, x| ((place >> plane) & 1) << (7 - x) } }

  # THE ENCODERS, each from its console's hardware.
  # The Game Boy Color's tile, and the Super Nintendo's tile of four colours: two bytes a row,
  # plane 0 then plane 1.
  TWO_PLANES = ->(places) { ROWS.(places).flat_map { |row| [PLANE.(row, 0), PLANE.(row, 1)] }.pack("C*") }
  # The Super Nintendo's tile of sixteen colours: planes 0 and 1 for the eight rows, then 2 and 3.
  FOUR_PLANES = lambda do |places|
    rows = ROWS.(places)
    (rows.flat_map { |row| [PLANE.(row, 0), PLANE.(row, 1)] } + rows.flat_map { |row| [PLANE.(row, 2), PLANE.(row, 3)] }).pack("C*")
  end
  # The Genesis's tile: two pixels a byte, the left one in the high half.
  HIGH_HALF_FIRST = ->(places) { places.each_slice(2).map { |left, right| (left << 4) | right }.pack("C*") }
  # Colours of fifteen bits, red lowest, low byte first: the Color's and the Super Nintendo's.
  FIFTEEN_BITS = ->(colors) { colors.pack("v*") }
  # The Genesis's colours: high byte first, three bits a channel, red at bit 1, green 5, blue 9.
  NINE_BITS = ->(_colors) { LEVELS.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*") }

  # One made-up original: the platform it names, what each slot line adds to say its layout, its
  # tiles' places and how many colours of the palette they pick from, and how it keeps tiles,
  # colours and numbers.
  Layout = Data.define(:title, :platform, :slot_options, :tiles, :bank_size, :tile_encoder, :color_encoder, :high_byte_first) do
    def copy
      bytes = (0...COPY_SIZE).map { |at| ((at * 37) + 11) & 0xFF }.pack("C*")
      colors = color_encoder.(PALETTE)
      bytes[PALETTE_AT, colors.bytesize] = colors
      bytes[TILES_AT, tile_bytes.bytesize] = tile_bytes
      bytes[SPEEDS_AT, SPEEDS.length * 2] = SPEEDS.pack(high_byte_first ? "n*" : "v*")
      bytes[OFFSETS_AT, OFFSETS.length * 2] = offset_bytes
      bytes[WORDS_AT, WORDS.length * 4] = word_bytes
      bytes
    end

    def tile_bytes = tiles.map(&tile_encoder).join

    def raw_color_bytes = color_encoder.(PALETTE)

    def raw_speed_bytes = SPEEDS.pack(high_byte_first ? "n*" : "v*")

    def offset_bytes = OFFSETS.pack(high_byte_first ? "s>*" : "s<*")

    def word_bytes = WORDS.pack(high_byte_first ? "l>*" : "l<*")
  end

  LAYOUTS = [
    Layout.new(title: "the Color's", platform: :gbc, slot_options: {}, tiles: FOUR_COLOR_TILES, bank_size: 4,
               tile_encoder: TWO_PLANES, color_encoder: FIFTEEN_BITS, high_byte_first: false),
    Layout.new(title: "the Super Nintendo's of four colours", platform: :snes, slot_options: { colors: 4 },
               tiles: FOUR_COLOR_TILES, bank_size: 4, tile_encoder: TWO_PLANES, color_encoder: FIFTEEN_BITS, high_byte_first: false),
    Layout.new(title: "the Super Nintendo's of sixteen colours", platform: :snes, slot_options: { colors: 16 },
               tiles: SIXTEEN_COLOR_TILES, bank_size: 16, tile_encoder: FOUR_PLANES, color_encoder: FIFTEEN_BITS, high_byte_first: false),
    Layout.new(title: "the Genesis's", platform: :genesis, slot_options: {}, tiles: SIXTEEN_COLOR_TILES, bank_size: 16,
               tile_encoder: HIGH_HALF_FIRST, color_encoder: NINE_BITS, high_byte_first: true),
    Layout.new(title: "a computer game's, in the Genesis's layout", platform: :pc, slot_options: { layout: :genesis },
               tiles: SIXTEEN_COLOR_TILES, bank_size: 16, tile_encoder: HIGH_HALF_FIRST, color_encoder: NINE_BITS, high_byte_first: true),
    Layout.new(title: "a computer game's, in the Color's layout", platform: :pc, slot_options: { layout: :gbc },
               tiles: FOUR_COLOR_TILES, bank_size: 4, tile_encoder: TWO_PLANES, color_encoder: FIFTEEN_BITS, high_byte_first: false)
  ].freeze

  VBlank::Testing::InRactors.share_constants(self)

  # +layout+'s made-up original, written into +folder+.
  private def layout_original(folder, layout)
    copy = layout.copy
    path = File.join(folder, "made_up_#{layout.platform}.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: layout.platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => COPY_SIZE } })
  end

  # The game: the two tiles laid out as a background, and a marker whose place across the screen is
  # the low byte of a number read from the table each frame. +data+ hands over the colours, each
  # tile's places and the table, from the pack or held directly.
  private def layout_game(data, options: VBlank::Cartridge::Options.new)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      colors, first, second, speeds, offsets, words = data.call(self)
      image :wall_a, width: 8, height: 8, colors: colors, places: first
      image :wall_b, width: 8, height: 8, colors: colors, places: second
      image :marker, width: 8, height: 8, colors: %i[transparent white], places: [1] * 64
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      marker = sprite :marker, at: [0, 60]
      step = var :step, 0
      game_loop do
        wait_vblank
        marker.move_to speeds[step] & 0xFF, 60 + offsets[step] + ((words[step] >> 24) & 7) + (words[step] & 7)
        step = (step + 1) & 7
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # The game reading +layout+'s made-up original, +from+, through its pack.
  private def through_layout_pack(from, layout)
    lambda do |builder|
      pack = builder.data_pack(from: from, version: "1") do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16, **layout.slot_options.slice(:layout)
        slots.tiles :walls, at: TILES_AT, count: 2, **layout.slot_options
        slots.numbers :speeds, at: SPEEDS_AT, count: 8, width: :half, signed: false, **layout.slot_options.slice(:layout)
        slots.numbers :offsets, at: OFFSETS_AT, count: 8, width: :half, signed: true, **layout.slot_options.slice(:layout)
        slots.numbers :words, at: WORDS_AT, count: 8, width: :word, signed: true, **layout.slot_options.slice(:layout)
      end
      [pack[:palette].bank(0, size: layout.bank_size), pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:speeds]),
       builder.table(:offsets, pack[:offsets]), builder.table(:words, pack[:words])]
    end
  end

  # +layout+'s made-up original on a machine where no copy of it is set.
  private def layout_original_nowhere(folder, layout)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, platform: layout.platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(layout.copy), "size" => COPY_SIZE } })
  end

  # The same game holding +layout+'s colours, tiles and numbers itself.
  private def layout_held_directly(layout)
    lambda do |builder|
      [PALETTE.first(layout.bank_size), layout.tiles[0], layout.tiles[1], builder.table(:speeds, SPEEDS, width: :half, signed: false),
       builder.table(:offsets, OFFSETS, width: :half, signed: true), builder.table(:words, WORDS, width: :word, signed: true)]
    end
  end
end
