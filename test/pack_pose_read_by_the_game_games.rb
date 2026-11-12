# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A MADE-UP ORIGINAL WHOSE FRAMES NO OPTION OF Original::FrameLayout READS, and a game that reads
# them with a reader of its own (FrameLayout's piece:), given a value from each pose. Shared by the
# test that holds the poses to the same pieces painted by hand
# (test/all/vblank/builder/test_pack_poses_read_by_the_game.rb) and the registry of pack games
# (test/pack_games.rb), which plays it with the pack left out too.
#
# The original keeps a piece as five bytes: x and y (signed, from the object's place), a ROW, a
# TILE and flags (bit 5 big, bit 6 mirrored, bit 7 upside down). The row does not count rows of
# sprite memory: it names a BLOCK of it, counted from the object's own block, which the object
# holds and the frame does not. Sprite memory is rows of 16 tiles, and a block is 8 tiles across
# and 4 down, two blocks across a row of the page; the piece's first tile is the block's first
# tile with the tile byte ORed in. So one frame shows other tiles for each object that uses it.
module PackPoseReadByTheGameGames
  include SharedConstants

  # Where each block starts in sprite memory, written out as the original's own table is: the
  # answer key the reader's sums are held to.
  BLOCK_STARTS = [0, 8, 64, 72, 128, 136, 192, 200, 256, 264, 320, 328, 384, 392, 448, 456].freeze

  # THE GAME'S READER. The block's start is worked out with shifts and sums, since the reader runs
  # as game code when the pack is read as the game starts, and a game's value cannot index a table.
  BLOCK_START = ->(block) { ((block & 1) << 3) + (((block >> 1) & 3) << 6) + ((block >> 3) << 8) }
  READ_PIECE = lambda do |bytes, pose|
    block = (bytes[2] + pose[:block]) & 15
    big = (bytes[4] >> 5) & 1
    VBlank::Original::FrameLayout::Piece.new(
      x: bytes.signed(0), y: bytes.signed(1), tile: BLOCK_START.(block) | bytes[3], columns: big + 1, rows: big + 1,
      row_step: 16, mirrored: (bytes[4] >> 6) & 1, upside_down: (bytes[4] >> 7) & 1
    )
  end
  FRAME = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, piece: READ_PIECE)

  # One piece of the made-up frame: where it is from the object's place, its row and tile bytes,
  # and its turns.
  Piece = Data.define(:x, :y, :row, :tile, :big, :mirrored, :upside_down) do
    def initialize(x:, y:, row:, tile:, big: false, mirrored: false, upside_down: false) = super

    def bytes = [x & 0xFF, y & 0xFF, row, tile, (big ? 0x20 : 0) | (mirrored ? 0x40 : 0) | (upside_down ? 0x80 : 0) | 0x0F]
    def side = big ? 2 : 1

    # Its first tile for an object whose block is +block+.
    def first_tile(block) = BLOCK_STARTS.fetch((row + block) & 15) | tile
  end

  PIECES = [
    Piece.new(x: -8, y: -8, row: 0, tile: 0x01),
    Piece.new(x: 0, y: -8, row: 1, tile: 0x02, mirrored: true),
    Piece.new(x: -8, y: 0, row: 3, tile: 0x12, big: true, upside_down: true),
    Piece.new(x: 8, y: 0, row: 2, tile: 0x04, mirrored: true, upside_down: true)
  ].freeze
  FRAME_BYTES = [PIECES.length, *PIECES.flat_map(&:bytes)].freeze

  # The two objects: a craft in block 5 and a line of text in block 0, showing the same frame.
  CRAFT_BLOCK = 5
  TEXT_BLOCK = 0

  # Four colours a tile, so the Game Boy Color shows them too; each tile a little different.
  TILE_COUNT = 320
  VIDEO = Array.new(TILE_COUNT) do |tile|
    (0...64).map { |at| ((at % 8) + ((at / 8) * 3) + (tile * 5) + (tile / 7) + ((at / 8) * (tile % 3))) % 4 }
  end.freeze
  COLORS = MadeUpOriginalLayouts::PALETTE.first(4).freeze

  FRAMES_AT = 0x20
  TILES_AT = 0x100
  ORIGIN = [8, 8].freeze
  REACH = [24, 24].freeze
  CRAFT_AT = [40, 40].freeze
  TEXT_AT = [100, 40].freeze

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def original(folder)
    tiles = VIDEO.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[FRAMES_AT, FRAME_BYTES.length] = FRAME_BYTES.pack("C*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up_blocks.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing the pose :craft at CRAFT_AT and :text at TEXT_AT, and the pack file its build
  # made (nil for a game with no pack, or a build that leaves its pack out). +poses+ declares them.
  private def game_of_two_poses_and_file(options: VBlank::Cartridge::Options.new, &poses)
    b = game_of_two_poses_builder(options: options, &poses)
    [b.program, b.made_data_pack_file]
  end

  # The same game's builder, its program made, for a test of its pack's unpacking.
  private def game_of_two_poses_builder(options: VBlank::Cartridge::Options.new, &poses)
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, *COLORS.drop(1)]
      instance_eval(&poses)
      sprite :craft, image: :craft, at: CRAFT_AT
      sprite :text, image: :text, at: TEXT_AT
      game_loop { wait_vblank }
    end
    b.finalize_program
    b
  end

  private def poses_read_by_the_game_and_file(from, options: VBlank::Cartridge::Options.new)
    b = poses_read_by_the_game_builder(from, options: options)
    [b.program, b.made_data_pack_file]
  end

  private def poses_read_by_the_game_builder(from, options: VBlank::Cartridge::Options.new)
    game_of_two_poses_builder(options: options) do
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sprites, at: TILES_AT, count: TILE_COUNT, colors: 16
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.length, width: :byte, signed: false
      end
      image :craft, tiles: pack[:sprites], frame: pack[:frames].frame(0, layout: FRAME, with: { block: CRAFT_BLOCK }),
                    origin: ORIGIN, colors: :ink, size: REACH
      image :text, tiles: pack[:sprites], frame: pack[:frames].frame(0, layout: FRAME, with: { block: TEXT_BLOCK }),
                   origin: ORIGIN, colors: :ink, size: REACH
    end
  end
end
