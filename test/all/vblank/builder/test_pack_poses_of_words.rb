# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# The made-up original these tests read and the games that show its frame, shared with the tests
# of the same game built with its pack left out (test/pack_pose_at_start_tests.rb).
module PackPoseOfWordsGames
  include SharedConstants

  # Tiles of four colours, so the Game Boy Color can show them too, each different from every
  # other and from itself turned.
  TILE_COUNT = 20
  VIDEO = Array.new(TILE_COUNT) do |tile|
    (0...64).map { |at| (((at % 8) * (at % 8)) + (3 * (at / 8)) + (tile * ((at % 8) + 1)) + ((tile * (at / 8)) / 2)) % 4 }
  end.freeze
  COLORS = MadeUpOriginalLayouts::PALETTE.first(4).freeze

  # One piece of the made-up frame: where it is from the object's place, its first tile, and how
  # many tiles it is across and down.
  Piece = Data.define(:x, :y, :tile, :columns, :rows, :mirrored, :upside_down) do
    def initialize(x:, y:, tile:, columns:, rows:, mirrored: false, upside_down: false) = super
  end

  # Five pieces about the object's place: a square, a column, three by two mirrored (which a
  # picture's pieces of 8x8 and 16x16 cannot hold as one), a row, and one tile upside down.
  PIECES = [
    Piece.new(x: -16, y: -16, tile: 0, columns: 2, rows: 2),
    Piece.new(x: 0, y: -16, tile: 4, columns: 1, rows: 2),
    Piece.new(x: -16, y: 0, tile: 6, columns: 3, rows: 2, mirrored: true),
    Piece.new(x: 8, y: -16, tile: 12, columns: 4, rows: 1),
    Piece.new(x: 8, y: 0, tile: 16, columns: 1, rows: 1, upside_down: true)
  ].freeze
  ORIGIN = [16, 16].freeze

  # The video chip's entry with the object's place taken off. The size byte holds the width in
  # tiles less one in bits 2 and 3 and the height less one in bits 0 and 1. The tile word holds
  # the tile in its low 11 bits, mirrored in bit 11 and upside down in bit 12; bits 13 to 15 (the
  # line of colours and the priority) are set here on every piece, and a pose does not read them.
  FRAME = VBlank::Original::FrameLayout.new(
    piece_bytes: 8, counted: true, count_bytes: 2, high_byte_first: true,
    y_at: 0, x_at: 6, position_bytes: 2, tile_at: 4, tile_bytes: 2, tile_bits: 11,
    flags_at: 4, flags_bytes: 2, mirrored_bit: 11, upside_down_bit: 12,
    size_at: 2, columns_bit: 2, rows_bit: 0, size_bits: 2, tile_order: :down_columns
  )

  TILES_AT = 0x100
  FRAMES_AT = 0x20
  # The picture the frame's pieces reach: seven tiles across and four down.
  REACH = [56, 32].freeze

  # The video chip reads a sprite's tiles down a column before it goes across.
  DOWN_COLUMNS = ->(piece, column, row) { piece.tile + (column * piece.rows) + row }
  ACROSS_ROWS = ->(piece, column, row) { piece.tile + (row * piece.columns) + column }

  VBlank::Testing::InRactors.share_constants(self)

  private def frame_bytes(high_byte_first)
    word, signed = high_byte_first ? ["n", "s>"] : ["v", "s<"]
    records = PIECES.map do |piece|
      tile_word = piece.tile | (piece.mirrored ? 0x0800 : 0) | (piece.upside_down ? 0x1000 : 0) | 0xE000
      [piece.y, ((piece.columns - 1) << 2) | (piece.rows - 1), 0x5A, tile_word, piece.x].pack("#{signed}CC#{word}#{signed}")
    end
    [PIECES.length].pack(word) + records.join
  end

  private def original(folder, high_byte_first: true)
    tiles = VIDEO.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    frames = frame_bytes(high_byte_first)
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[FRAMES_AT, frames.bytesize] = frames
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing a pose as a sprite at (40, 40), and the pack file its build made (nil for a
  # game with no pack, or a build that leaves its pack out). +pose+ declares the picture :pose.
  private def game_showing_and_file(...)
    b = game_showing_builder(...)
    [b.program, b.made_data_pack_file]
  end

  # The same game's builder, its program made, for a test of its pack's unpacking.
  private def game_showing_builder(options: VBlank::Cartridge::Options.new, &pose)
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      colors :hero, [:transparent, *COLORS.drop(1)]
      instance_eval(&pose)
      sprite :hero, image: :pose, at: [40, 40]
      game_loop { wait_vblank }
    end
    b.finalize_program
    b
  end

  private def game_showing(...) = game_showing_and_file(...).first

  private def pose_from_pack_and_file(...)
    b = pose_from_pack_builder(...)
    [b.program, b.made_data_pack_file]
  end

  private def pose_from_pack_builder(from, layout: FRAME, options: VBlank::Cartridge::Options.new, **pose_options)
    frame_length = 2 + (PIECES.length * 8)
    game_showing_builder(options: options) do
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sprites, at: TILES_AT, count: TILE_COUNT
        slots.numbers :frames, at: FRAMES_AT, count: frame_length, width: :byte, signed: false
      end
      image :pose, tiles: pack[:sprites], frame: pack[:frames].frame(0, layout: layout), origin: ORIGIN, colors: :hero,
                   **pose_options
    end
  end

  private def pose_from_pack(...) = pose_from_pack_and_file(...).first
end

# A POSE READ FROM AN ORIGINAL THAT KEEPS A FRAME AS THE CONSOLE'S OWN SPRITE ENTRIES
# (Original::FrameLayout's parts of two bytes, and its pieces of several tiles each way). The
# made-up original keeps a frame as a Genesis game does: a word that counts the pieces, then eight
# bytes a piece, which are y as a word, a size byte, a byte the picture does not use, the tile
# word and x as a word. The answer key is the same pieces painted by hand, a tile at a time,
# worked out here from what the video chip does with such an entry.
class TestPackPosesOfWords < Minitest::Test
  include PackPoseOfWordsGames

  # THE SAME PIECES PAINTED BY HAND, one tile of 8x8 at a time. +tile_of+ is the tile a piece
  # holds at a column and row of itself. A piece that is mirrored shows its last column first,
  # each tile back to front; one that is upside down shows its last row first, each tile's rows
  # in reverse.
  private def pose_painted_by_hand(tile_of)
    painted = PIECES.flat_map do |piece|
      (0...piece.columns).to_a.product((0...piece.rows).to_a).map do |column, row|
        rows = VIDEO.fetch(tile_of.call(piece, column, row)).each_slice(8).to_a
        rows = rows.map(&:reverse) if piece.mirrored
        rows = rows.reverse if piece.upside_down
        shown_column = piece.mirrored ? piece.columns - 1 - column : column
        shown_row = piece.upside_down ? piece.rows - 1 - row : row
        [ORIGIN[0] + piece.x + (shown_column * 8), ORIGIN[1] + piece.y + (shown_row * 8), rows.flatten]
      end
    end
    game_showing { image :pose, pieces: painted, colors: :hero }
  end

  def test_a_frame_of_words_draws_its_pieces_of_mixed_sizes_as_painted_by_hand
    Dir.mktmpdir do |folder|
      read = game_player.run(pose_from_pack(original(folder)), frames: 4).screen
      painted = game_player.run(pose_painted_by_hand(DOWN_COLUMNS), frames: 4).screen

      assert_equal painted.to_a, read.to_a
      # The mirrored piece's top left pixel is the top right pixel of its LAST column's first tile.
      place = VIDEO.fetch(6 + (2 * 2)).fetch(7)

      refute_equal 0, place, "the pixel this test reads must not be see-through"
      assert_equal COLORS.fetch(place), read.pixel(40, 56), "the mirrored piece's top left pixel"
    end
  end

  def test_a_layout_of_tiles_across_rows_draws_them_so
    Dir.mktmpdir do |folder|
      read = game_player.run(pose_from_pack(original(folder), layout: FRAME.with(tile_order: :across_rows)), frames: 4).screen
      painted = game_player.run(pose_painted_by_hand(ACROSS_ROWS), frames: 4).screen
      down_columns = game_player.run(pose_painted_by_hand(DOWN_COLUMNS), frames: 4).screen

      assert_equal painted.to_a, read.to_a
      refute_equal down_columns.to_a, read.to_a
    end
  end

  def test_a_layout_of_low_bytes_first_reads_its_words_so
    Dir.mktmpdir do |folder|
      from = original(folder, high_byte_first: false)
      read = game_player.run(pose_from_pack(from, layout: FRAME.with(high_byte_first: false)), frames: 4).screen
      painted = game_player.run(pose_painted_by_hand(DOWN_COLUMNS), frames: 4).screen

      assert_equal painted.to_a, read.to_a
    end
  end

  def test_a_layout_of_words_with_no_byte_order_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(high_byte_first: nil) }

    assert_includes error.message, "high_byte_first:"
  end

  def test_a_layout_with_a_size_byte_and_no_tile_order_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(tile_order: nil) }

    assert_includes error.message, "tile_order:"
  end

  def test_a_layout_with_a_size_byte_and_a_big_bit_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(big_bit: 13) }

    assert_includes error.message, "big_bit:"
  end

  def test_a_layout_whose_word_ends_past_its_piece_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(x_at: 7) }

    assert_includes error.message, "piece_bytes"
  end
end
