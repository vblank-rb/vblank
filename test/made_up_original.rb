# frozen_string_literal: true

require "digest"
require "tmpdir"

# THE MADE-UP ORIGINAL AND THE GAME READING IT, shared by the data pack, copy reader, packing, shell and pack-at-start tests:
# the same game built with its data left out, handed its pack as it starts.
module MadeUpOriginal
  # Sixteen colours: place 0 see-through, then red, green, blue, white and a run of greys.
  PALETTE = [0x0000, 0x001F, 0x03E0, 0x7C00, 0x7FFF, *(1..11).map { |grey| grey * 0x0421 }].freeze
  # Two 8x8 tiles as their places: stripes of three colours, and a diagonal over two greys. Each
  # keeps to three colours, so it fits a Game Boy Color's square of four with black.
  TILE_PLACES = [(0...64).map { |at| 1 + ((at + (at / 8)) % 3) },
                 (0...64).map { |at| (at % 8) == (at / 8) ? 4 : 5 + (at % 2) }].freeze
  SPEEDS = [10, 30, 50, 70, 90, 110, 130, 150].freeze

  # Heights with long runs in them, which the made-up original keeps packed with RLE.
  HEIGHTS = ([3] * 10 + [7, 8] + [1] * 12 + [4, 4, 9]).freeze

  PALETTE_AT = 0x10
  TILES_AT = 0x40
  SPEEDS_AT = 0xA0
  NUDGES_AT = 0xB0
  SPRITES_AT = 0xC0
  LZ77_AT = 0x140
  RLE_AT = 0x1A0
  COPY_SIZE = 0x200

  # A 16x16 picture as its places, row by row: see-through in a slanting pattern, and the rest in
# eleven colours, so a turned copy of it differs from it at every row and column.
SPRITE_PLACES = (0...16).flat_map { |y| (0...16).map { |x| ((x * 3) + (y * 5)) % 6 == 0 ? 0 : 1 + ((x + (2 * y)) % 11) } }.freeze

# The picture as the original keeps it: four tiles, left to right and top to bottom, each two pixels a byte.
SPRITE_BYTES = [0, 1, 2, 3].flat_map do |tile|
  (0...64).map { |at| SPRITE_PLACES[((((tile / 2) * 8) + (at / 8)) * 16) + ((tile % 2) * 8) + (at % 8)] }
end.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*").freeze

# The tiles as the original keeps them: two pixels a byte, the left one in the low half.
  TILE_BYTES = TILE_PLACES.flatten.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*").freeze

  # The two packed blocks, written by BiosCompress, the packer the Game Boy Advance lowering uses
  # and the answer key for the unpacking: what it packs, the routine unpacks back to these bytes.
  Packer = VBlank::IR::Backends::GBA::BiosCompress
  LZ77_BLOCK = Packer.with_bios_header(Packer.lz77(TILE_BYTES), Packer::TYPE_LZ77, TILE_BYTES.bytesize).freeze
  RLE_BLOCK = Packer.with_bios_header(Packer.rle(HEIGHTS.pack("C*")), Packer::TYPE_RLE, HEIGHTS.length).freeze

  # The made-up original: filler bytes, with the colours, the tiles and the table written where
  # the port's slots say they are, and the same tiles again packed with LZ77, and the heights
  # packed with RLE.
  COPY = begin
    bytes = (0...COPY_SIZE).map { |at| (at * 37 + 11) & 0xFF }.pack("C*")
    bytes[PALETTE_AT, 32] = PALETTE.pack("v*")
    bytes[TILES_AT, TILE_BYTES.bytesize] = TILE_BYTES
    bytes[SPEEDS_AT, SPEEDS.length] = SPEEDS.pack("C*")
    bytes[NUDGES_AT, 2] = [0xF6, 0x0A].pack("C*")
    bytes[SPRITES_AT, SPRITE_BYTES.bytesize] = SPRITE_BYTES
    bytes[LZ77_AT, LZ77_BLOCK.bytesize] = LZ77_BLOCK
    bytes[RLE_AT, RLE_BLOCK.bytesize] = RLE_BLOCK
    bytes.freeze
  end
  SHA1 = Digest::SHA1.hexdigest(COPY)

  # A second release of the made-up original: the same data, every piece EU_SHIFT bytes later.
  EU_SHIFT = 0x40
  COPY_EU = ("\xAA".b * EU_SHIFT + COPY).freeze
  SHA1_EU = Digest::SHA1.hexdigest(COPY_EU)

  # Shareable, as a test class's own constants are made (test_helper.rb), since a test may run in
  # a Ractor and these are a module's.
  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def original(folder)
    path = File.join(folder, "made_up.gba")
    File.binwrite(path, COPY)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path },
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # The made-up original with two releases, US (COPY) and EU (COPY_EU), whose copy is the file at
  # +path+ in +folder+ (nil for a machine with no copy).
  private def two_release_original(folder, copy: nil)
    path = copy && File.join(folder, "made_up.gba")
    File.binwrite(path, copy) if path
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: path ? { "MADE_UP_ROM" => path } : {},
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "US" => { "sha1" => SHA1, "size" => COPY_SIZE },
                                           "EU" => { "sha1" => SHA1_EU, "size" => COPY_SIZE + EU_SHIFT } })
  end

  # The slots of ShellTests#port for the two releases: the colours copied from a place for each
  # release, the tiles and heights unpacked by a routine that picks its places by release name.
  private def two_release_slots(slots)
    slots.colors :palette, at: { "US" => PALETTE_AT, "EU" => PALETTE_AT + EU_SHIFT }, count: 16
    slots.tiles :walls, count: 2
    slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
    slots.fill_from_copy do |copy, into, release|
      shift = release == "EU" ? EU_SHIFT : 0
      copy.unpack_lz77 at: LZ77_AT + shift, into: into[:walls]
      copy.unpack_rle at: RLE_AT + shift, into: into[:heights]
    end
  end

  # A copy that is +bytes+ alone, written into +folder+, of an original for +platform+.
  private def copy_of(folder, bytes, platform: :gba)
    path = File.join(folder, "packed.bin")
    File.binwrite(path, bytes)
    VBlank::Original::Copy.new(path: path, sha1: Digest::SHA1.hexdigest(bytes), release: "Test", platform: platform)
  end

  # The game: the two tiles laid out as a background, and a marker whose place across the screen
  # is read from the table each frame. +data+ hands over the colours, each tile's places and the
  # table, from the pack or held directly. +options+ are the build's (Cartridge::Options).
  private def game_program(data, options: VBlank::Cartridge::Options.new)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      colors, first, second, speeds = data.call(self)
      image :wall_a, width: 8, height: 8, colors: colors, places: first
      image :wall_b, width: 8, height: 8, colors: colors, places: second
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      step = var :step, 0
      game_loop do
        wait_vblank
        draw_rect_at speeds[step], 40, 4, 4, :white
        step = (step + 1) & 7
      end
    end
    b.finalize_program
    b.program
  end

  private def made_up_pack(builder, folder)
    builder.data_pack(from: original(folder), version: "1") do |slots|
      slots.colors :palette, at: PALETTE_AT, count: 16
      slots.tiles :walls, at: TILES_AT, count: 2
      slots.numbers :speeds, at: SPEEDS_AT, count: 8, width: :byte, signed: false
    end
  end

  private def through_pack(folder)
    lambda do |builder|
      pack = made_up_pack(builder, folder)
      [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:speeds])]
    end
  end

  private def held_directly
    lambda do |builder|
      [PALETTE, TILE_PLACES[0], TILE_PLACES[1], builder.table(:speeds, SPEEDS, width: :byte, signed: false)]
    end
  end

  # A PORT'S OWN UNPACKING ROUTINE. The tiles and the heights are packed in the made-up original,
  # so their slots say no place in the copy, and the routine fills them: the same routine the
  # build runs on the interpreter, and a player's machine runs as the shell starts.
  private def unpacked_pack(builder, folder)
    builder.data_pack(from: original(folder), version: "1") do |slots|
      slots.colors :palette, at: PALETTE_AT, count: 16
      slots.tiles :walls, count: 2
      slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
      slots.fill_from_copy do |copy, pack|
        copy.unpack_lz77 at: LZ77_AT, into: pack[:walls]
        copy.unpack_rle at: RLE_AT, into: pack[:heights]
      end
    end
  end
end
