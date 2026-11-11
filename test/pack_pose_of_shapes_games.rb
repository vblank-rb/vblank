# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A MADE-UP ADVANCE ORIGINAL WHOSE FRAME HAS A PIECE OF EVERY SHAPE AND SIZE THE CONSOLE'S SPRITES
# COME IN, kept as the console's own sprite entries (Original::FrameLayout's shape_bit: and
# shape_size_bit:), and a game that shows it as a pose. Shared by the test that holds it to the
# same pieces painted by hand (test/console/gba/vblank/builder/test_pack_poses_of_shapes_on_the_advance.rb)
# and the registry of pack games (test/pack_games.rb), which plays it with the pack left out too.
module PackPoseOfShapesGames
  include SharedConstants

  # The Advance's table of sprite sizes: [columns, rows] in tiles, by shape (square, wide, tall),
  # then by size. Written from the console's documentation, it is the answer key.
  SIZES = [
    [[1, 1], [2, 2], [4, 4], [8, 8]],
    [[2, 1], [4, 1], [4, 2], [8, 4]],
    [[1, 2], [1, 4], [2, 4], [4, 8]]
  ].freeze

  # One piece of the made-up frame: where its top left is in the picture, its first tile, and its
  # shape and size as the console keeps them.
  Piece = Data.define(:left, :top, :tile, :shape, :size, :mirrored, :upside_down) do
    def initialize(left:, top:, tile:, shape:, size:, mirrored: false, upside_down: false) = super

    def columns = SIZES.fetch(shape).fetch(size).first
    def rows = SIZES.fetch(shape).fetch(size).last
  end

  # Every shape at every size, side by side in a picture of 128 by 96, none over another. Each
  # takes the tiles after the one before's, so the frame names 177 tiles.
  PLACES = [[0, 0, 0, 3], [64, 0, 2, 3], [0, 64, 1, 3], [96, 0, 0, 2], [96, 32, 2, 2], [64, 64, 1, 2],
            [112, 32, 0, 1], [112, 48, 2, 1], [64, 80, 1, 1], [120, 48, 2, 0], [96, 80, 1, 0], [120, 64, 0, 0]].freeze
  PIECES = PLACES.each_with_object([]) do |(left, top, shape, size), pieces|
    tile = pieces.sum { |piece| piece.columns * piece.rows }
    # The tall piece of size 2 upside down and the wide one mirrored: a piece is turned whole.
    pieces << Piece.new(left: left, top: top, tile: tile, shape: shape, size: size,
                        upside_down: shape == 2 && size == 2, mirrored: shape == 1 && size == 2)
  end.freeze
  TILE_COUNT = PIECES.sum { |piece| piece.columns * piece.rows }
  ORIGIN = [64, 48].freeze
  REACH = [128, 96].freeze

  # Tiles of sixteen colours, each different from every other and from itself turned.
  VIDEO = Array.new(TILE_COUNT) do |tile|
    (0...64).map { |at| ((((at % 8) * ((at % 8) + 3)) + (5 * (at / 8)) + (tile * 7) + ((tile / 16) * (at / 8))) % 15) + 1 }
  end.freeze
  COLORS = MadeUpOriginalLayouts::PALETTE

  # The console's sprite entry with the object's place taken off, as an Advance game keeps a frame:
  # a count byte, then five bytes a piece. x and y are signed bytes; the flags byte holds the
  # shape in bits 6 and 7, the size in bits 4 and 5, mirrored in bit 2 and upside down in bit 3;
  # then a word, low byte first, whose low ten bits are the tile. Bits a pose does not read are set
  # on some pieces (bit 0 of the flags, and bits 10 and 12 of the word).
  FRAME = VBlank::Original::FrameLayout.new(
    piece_bytes: 5, counted: true, x_at: 0, y_at: 1, flags_at: 2, mirrored_bit: 2, upside_down_bit: 3,
    tile_at: 3, tile_bytes: 2, tile_bits: 10, high_byte_first: false, shape_bit: 6, shape_size_bit: 4,
    tile_order: :across_rows
  )

  TILES_AT = 0x100
  FRAMES_AT = 0x20
  FRAME_LENGTH = 1 + (PIECES.length * 5)

  # The console reads a sprite's tiles across a row before it goes down.
  ACROSS_ROWS = ->(piece, column, row) { piece.tile + (row * piece.columns) + column }
  # One tile of sixteen colours as the Advance keeps it: two pixels a byte, the left in the low half.
  LOW_HALF_FIRST = ->(places) { places.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*") }

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def frame_bytes
    records = PIECES.each_with_index.map do |piece, at|
      flags = (piece.shape << 6) | (piece.size << 4) | (piece.mirrored ? 4 : 0) | (piece.upside_down ? 8 : 0) | (at % 2)
      word = piece.tile | (at.odd? ? 0x1400 : 0)
      [piece.left - ORIGIN[0], piece.top - ORIGIN[1], flags, word].pack("ccCv")
    end
    [PIECES.length].pack("C") + records.join
  end

  private def original(folder)
    tiles = VIDEO.map(&LOW_HALF_FIRST).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[FRAMES_AT, FRAME_LENGTH] = frame_bytes
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up_shapes.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing a pose as a sprite whose top left is at (80, 60), and the pack file its build made (nil for a
  # game with no pack, or a build that leaves its pack out). +pose+ declares the picture :pose.
  private def game_showing_shapes_and_file(options: VBlank::Cartridge::Options.new, &pose)
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      colors :hero, [:transparent, *COLORS.drop(1)]
      instance_eval(&pose)
      sprite :hero, image: :pose, at: [80, 60]
      game_loop { wait_vblank }
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  private def pose_of_shapes_and_file(from, options: VBlank::Cartridge::Options.new)
    game_showing_shapes_and_file(options: options) do
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sprites, at: TILES_AT, count: TILE_COUNT
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_LENGTH, width: :byte, signed: false
      end
      image :pose, tiles: pack[:sprites], frame: pack[:frames].frame(0, layout: FRAME), origin: ORIGIN, colors: :hero, size: REACH
    end
  end
end
