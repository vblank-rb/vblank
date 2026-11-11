# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A POSE THAT IS ONE OF THE ORIGINAL'S OWN FRAMES (Builder::PackPoses), read from a made-up original
# that keeps its frames as many retail games do: a count, then five bytes a piece. The answer key is
# the made-up frame itself: each piece's tile, turned as it says, where it says from the origin.
class TestPackPoses < Minitest::Test
  # Four colours a tile, so the Game Boy Color can show them too. No row or column reads the same
  # both ways.
  PLACES = [
    Array.new(64, 0),
    (0...64).map { |at| ((at % 8) + (2 * (at / 8))) % 4 },
    (0...64).map { |at| (at / 8).even? ? 1 + ((at % 8) / 3) : 3 },
    (0...64).map { |at| at % 8 < 4 ? 2 : 1 }
  ].freeze
  # Sprite memory of 32 tiles, sixteen to a row: a big piece at tile 2 is tiles 2, 3, 18 and 19.
  VIDEO = Array.new(32) { |at| PLACES.fetch(at % 4) }.freeze
  COLORS = MadeUpOriginalLayouts::PALETTE.first(4).freeze

  # A piece: x and y (signed, from the object's place), the row of sprite memory, the tile along
  # it, and the flags: mirrored bit 6, upside down bit 7, big bit 5.
  FRAME = VBlank::Original::FrameLayout.new(piece_bytes: 5, counted: true, x_at: 0, y_at: 1, tile_row_at: 2, tile_at: 3,
                                            row_tiles: 16, flags_at: 4, mirrored_bit: 6, upside_down_bit: 7, big_bit: 5)
  PIECE = ->(x, y, tile, mirrored: false, upside_down: false, big: false) do
    [x & 0xFF, y & 0xFF, tile / 16, tile % 16, (mirrored ? 0x40 : 0) | (upside_down ? 0x80 : 0) | (big ? 0x20 : 0) | 0x0E]
  end
  # Three pieces about the object's place: a tile above and left of it, the same tile mirrored above
  # and right, and a big piece upside down below.
  PIECES = [PIECE.(-8, -8, 1), PIECE.(0, -8, 1, mirrored: true), PIECE.(-8, 0, 2, upside_down: true, big: true)].freeze
  FRAME_BYTES = ([0xFF] + [PIECES.length] + PIECES.flatten).freeze

  TILES_AT = 0x100
  FRAMES_AT = 0x20

  private def original(folder)
    tiles = VIDEO.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[FRAMES_AT, FRAME_BYTES.length] = FRAME_BYTES.pack("C*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing the frame at byte 1 of the slot (byte 0 is another frame's) as a sprite at (40, 40).
  private def pose_game(from, origin: [8, 8], frame_at: 1, layout: FRAME, count: nil, &more)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      colors :hero, [:transparent, *COLORS.drop(1)]
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sprites, at: TILES_AT, count: 32, colors: 16
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.length, width: :byte, signed: false
      end
      image :pose, tiles: pack[:sprites], frame: pack[:frames].frame(frame_at, layout: layout, count: count),
                   origin: origin, colors: :hero
      hero = sprite :hero, image: :pose, at: [40, 40]
      instance_exec(hero, &more) if more
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The picture the frame makes, worked out from the made-up data: 16 wide and 24 tall.
  private def expected_places
    picture = Array.new(24) { Array.new(16, 0) }
    stamp = lambda do |left, top, rows|
      rows.each_with_index { |row, y| row.each_with_index { |place, x| picture[top + y][left + x] = place } }
    end
    tile = PLACES[1].each_slice(8).to_a
    stamp.(0, 0, tile)
    stamp.(8, 0, tile.map(&:reverse))
    big = Array.new(16) { |y| Array.new(16) { |x| VIDEO.fetch(2 + ((y / 8) * 16) + (x / 8)).fetch(((y % 8) * 8) + (x % 8)) } }
    stamp.(0, 8, big.reverse)
    picture
  end

  def test_a_frames_pieces_show_their_tiles_turned_where_the_frame_puts_them
    Dir.mktmpdir do |folder|
      screen = game_player.run(pose_game(original(folder)), frames: 4).screen
      backdrop = screen.pixel(120, 120)

      expected_places.each_with_index do |row, y|
        row.each_with_index do |place, x|
          want = place.zero? ? backdrop : COLORS.fetch(place)

          assert_equal want, screen.pixel(40 + x, 40 + y), "the pose's pixel at (#{x}, #{y})"
        end
      end
    end
  end

  # A frame whose layout does not carry its count is read with the count the game gives.
  def test_a_frame_of_a_given_count_reads_that_many_pieces
    uncounted = FRAME.with(counted: false)
    Dir.mktmpdir do |folder|
      counted = game_player.run(pose_game(original(folder)), frames: 4).screen.to_a
      given = game_player.run(pose_game(original(folder), frame_at: 2, layout: uncounted, count: PIECES.length), frames: 4)

      assert_equal counted, given.screen.to_a
    end
  end

  def test_a_pose_draws_with_another_list_by_place
    other = MadeUpOriginalLayouts::PALETTE.last(4)
    Dir.mktmpdir do |folder|
      program = pose_game(original(folder)) do |hero|
        colors :other, [:transparent, *other.drop(1)]
        hero.draw_with :other
      end
      screen = game_player.run(program, frames: 4).screen
      place = expected_places[0][1]

      assert_equal other.fetch(place), screen.pixel(41, 40), "the pose's pixel at (1, 0), drawn with :other"
    end
  end

  def test_a_piece_left_of_the_origin_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { pose_game(original(folder), origin: [4, 8]) }

      assert_includes error.message, "origin:"
    end
  end

  def test_a_frame_past_the_end_of_its_slot_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { pose_game(original(folder), frame_at: FRAME_BYTES.length - 2) }

      assert_includes error.message, "ends past the slot"
    end
  end

  def test_a_layout_naming_a_byte_past_its_piece_is_refused
    error = assert_raises(ArgumentError) do
      VBlank::Original::FrameLayout.new(piece_bytes: 4, counted: true, x_at: 0, y_at: 1, tile_at: 2, flags_at: 4,
                                        mirrored_bit: 6, upside_down_bit: 7)
    end

    assert_includes error.message, "piece_bytes"
  end
end
