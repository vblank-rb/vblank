# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# The made-up original these tests read and the games that show its frame, shared with the tests
# of the same game built with its pack left out (test/pack_pose_of_split_tiles_at_start_tests.rb).
module PackPoseOfSplitTileGames
  include SharedConstants

  # Sprite memory of more than 256 tiles, so a tile's number does not fit in a byte. Tiles of four
  # colours, each turned unlike itself, and tile t + 256 unlike tile t (the term t / 5), so a tile
  # read without its ninth bit is seen to be the wrong one. They are kept two bits a pixel, and
  # there are few past 256, so the pack's unpacking fits in a Game Boy Color's memory too.
  TILE_COUNT = 260
  VIDEO = Array.new(TILE_COUNT) do |tile|
    (0...64).map { |at| (((at % 8) * (at % 8)) + (3 * (at / 8)) + (tile * ((at % 8) + 1)) + ((tile * (at / 8)) / 2) + (tile / 5)) % 4 }
  end.freeze
  COLORS = MadeUpOriginalLayouts::PALETTE.first(4).freeze

  # One piece of the made-up frame: where it is from the object's place, its tile and its turns.
  Piece = Data.define(:x, :y, :tile, :mirrored, :upside_down) do
    def initialize(x:, y:, tile:, mirrored: false, upside_down: false) = super
  end

  # Four tiles about the object's place. Three of them are past tile 255, and the tile each would
  # be with its ninth bit lost (2, 3 and 1) is another picture.
  PIECES = [
    Piece.new(x: -8, y: -8, tile: 1),
    Piece.new(x: 0, y: -8, tile: 258, mirrored: true),
    Piece.new(x: -8, y: 0, tile: 259, upside_down: true),
    Piece.new(x: 0, y: 0, tile: 257)
  ].freeze
  ORIGIN = [8, 8].freeze
  REACH = [16, 16].freeze

  # A Super Nintendo's sprite entry with the object's place taken off: x, y, the low eight bits of
  # the tile, and a byte of flags whose bit 0 is the tile's NINTH bit, with mirrored in bit 6 and
  # upside down in bit 7. The bits between (the colours and the priority) are set on every piece.
  FRAME = VBlank::Original::FrameLayout.new(piece_bytes: 4, counted: true, x_at: 0, y_at: 1, tile_at: 2, flags_at: 3,
                                            mirrored_bit: 6, upside_down_bit: 7, tile_high_bit: 0, tile_high_bits: 1)
  FRAME_BYTES = [PIECES.length, *PIECES.flat_map do |piece|
    [piece.x & 0xFF, piece.y & 0xFF, piece.tile & 0xFF,
     (piece.tile >> 8) | (piece.mirrored ? 0x40 : 0) | (piece.upside_down ? 0x80 : 0) | 0x3E]
  end].freeze

  TILES_AT = 0x100
  FRAMES_AT = 0x20

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def original(folder)
    tiles = VIDEO.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[FRAMES_AT, FRAME_BYTES.length] = FRAME_BYTES.pack("C*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The builder of a game showing a pose as a sprite at (40, 40), its program made. +pose+ declares
  # the picture :pose.
  private def builder_showing(options: VBlank::Cartridge::Options.new, &pose)
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

  # The builder of the game whose pose is the made-up frame, read from the pack. Its slot of
  # frames is copied as it is: the game writes no unpacking routine.
  private def builder_reading_frame(from, options: VBlank::Cartridge::Options.new, **pose_options)
    builder_showing(options: options) do
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sprites, at: TILES_AT, count: TILE_COUNT, colors: 4
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.length, width: :byte, signed: false
      end
      image :pose, tiles: pack[:sprites], frame: pack[:frames].frame(0, layout: FRAME), origin: ORIGIN, colors: :hero,
                   **pose_options
    end
  end
end

# A POSE READ FROM AN ORIGINAL THAT KEEPS A TILE'S NUMBER IN TWO PLACES (Original::FrameLayout's
# `tile_high_bit:`): its low eight bits in a byte of their own and its ninth among the flags, as a
# Super Nintendo's sprite entry keeps it. The answer key is the same pieces painted by hand.
class TestPackPosesOfSplitTiles < Minitest::Test
  include PackPoseOfSplitTileGames

  # THE SAME PIECES PAINTED BY HAND, each the tile +tile_of+ gives for it, turned as it says.
  private def pose_painted_by_hand
    painted = PIECES.map do |piece|
      rows = VIDEO.fetch(yield(piece)).each_slice(8).to_a
      rows = rows.map(&:reverse) if piece.mirrored
      rows = rows.reverse if piece.upside_down
      [ORIGIN[0] + piece.x, ORIGIN[1] + piece.y, rows.flatten]
    end
    builder_showing { image :pose, pieces: painted, colors: :hero }.program
  end

  def test_a_tile_whose_high_bit_is_among_the_flags_is_drawn_as_painted_by_hand
    Dir.mktmpdir do |folder|
      read = game_player.run(builder_reading_frame(original(folder)).program, frames: 4).screen
      painted = game_player.run(pose_painted_by_hand(&:tile), frames: 4).screen
      low_bits_alone = game_player.run(pose_painted_by_hand { |piece| piece.tile & 0xFF }, frames: 4).screen

      assert_equal painted.to_a, read.to_a
      refute_equal low_bits_alone.to_a, read.to_a, "the tiles past 255 are other pictures than their low bits name"
    end
  end

  def test_a_high_bit_with_no_count_of_bits_is_refused
    error = assert_raises(ArgumentError) { FRAME.with(tile_high_bits: nil) }

    assert_includes error.message, "tile_high_bits:"
  end

  def test_high_bits_that_end_past_the_flags_are_refused
    error = assert_raises(ArgumentError) { FRAME.with(tile_high_bit: 7, tile_high_bits: 2) }

    assert_includes error.message, "tile_high_bit:"
  end
end
