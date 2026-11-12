# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A SCREEN DRAWN FROM ONE SLOT OF AN ORIGINAL'S TILES: a background of the slot and three poses read
# from the original's frames, every one drawn from the same ten tiles. The made-up original keeps
# them as a Genesis game does: a frame is a word that counts its pieces, then eight bytes a piece,
# and a piece is up to four tiles each way, its tiles one after another in the slot, down each
# column. The answer key is the made-up data: each piece's tiles where the frame puts them, turned
# as its word says.
#
# The poses share an origin of (4, 4), since pieces reach four pixels left of and above the object's
# place, so most pieces sit four pixels off the picture's own grid of 8.
module SharedSlotTilesGame
  # Tile 0 draws nothing. Tiles 1 to 10 each draw three colours all over, no two alike however
  # either is turned: tile n's top row starts with n pixels of place 3, and its other rows step
  # through the places from a start of their own.
  TILE = lambda do |n|
    (0...64).map do |at|
      x = at % 8
      y = at / 8
      next 0 if n.zero?

      y.zero? ? (x < n ? 3 : 1) : 1 + ((x + (2 * y) + n) % 3)
    end
  end
  TILES = (0..10).map(&TILE).freeze
  # How many of the slot's tiles the screen shows: every one but the blank.
  TILES_SHOWN = 10

  BANK = MadeUpOriginalLayouts::PALETTE

  FRAME = VBlank::Original::FrameLayout.new(
    piece_bytes: 8, counted: true, count_bytes: 2, high_byte_first: true,
    y_at: 0, x_at: 6, position_bytes: 2, tile_at: 4, tile_bytes: 2, tile_bits: 11,
    flags_at: 4, flags_bytes: 2, mirrored_bit: 11, upside_down_bit: 12, bank_bit: 13, bank_bits: 2,
    size_at: 2, columns_bit: 2, rows_bit: 0, size_bits: 2, tile_order: :down_columns
  )

  # A piece of a frame: where its top left is from the object's place, how many tiles across and
  # down it is, its first tile, and its turn.
  Piece = Data.define(:x, :y, :columns, :rows, :tile, :mirrored, :upside_down) do
    def initialize(x:, y:, columns:, rows:, tile:, mirrored: false, upside_down: false) = super

    # The eight bytes the original keeps it in: down, size, link, tile word, across.
    def bytes
      word = tile | (mirrored ? 1 << 11 : 0) | (upside_down ? 1 << 12 : 0) | 0x8000
      [y, ((columns - 1) << 2) | (rows - 1), 0, word, x].pack("s>CCns>")
    end

    # The slot's tile at column +column+ and row +row+ of the piece as it is shown, and the place
    # at (+x+, +y+) inside that square.
    def place_at(column, row, x, y)
      from_column = mirrored ? columns - 1 - column : column
      from_row = upside_down ? rows - 1 - row : row
      TILES.fetch(tile + (from_column * rows) + from_row)[((upside_down ? 7 - y : y) * 8) + (mirrored ? 7 - x : x)]
    end
  end

  # Each pose's pieces, the one in front first. :walk and :turn share the piece of tiles 1 to 4,
  # mirrored in :turn; :turn's second piece starts at the tile :walk's second is; :leap's big piece
  # takes those tiles in too. :walk's second piece lies partly under its first.
  POSES = {
    walk: [Piece.new(x: 0, y: -4, columns: 2, rows: 2, tile: 1), Piece.new(x: 12, y: 8, columns: 1, rows: 1, tile: 5)],
    turn: [Piece.new(x: 0, y: -4, columns: 2, rows: 2, tile: 1, mirrored: true), Piece.new(x: 16, y: -4, columns: 1, rows: 2, tile: 5)],
    leap: [Piece.new(x: 0, y: 0, columns: 3, rows: 2, tile: 5), Piece.new(x: 0, y: 16, columns: 2, rows: 1, tile: 3, upside_down: true)]
  }.freeze
  FRAME_BYTES = POSES.transform_values { |pieces| [pieces.length].pack("n") + pieces.map(&:bytes).join }.freeze
  # Where each pose's frame starts in the slot of frames, one after another.
  FRAMES_AT_OF = POSES.keys.each_with_index.to_h { |name, at| [name, FRAME_BYTES.values.first(at).sum(&:bytesize)] }.freeze
  ORIGIN = [4, 4].freeze
  # Where each pose's sprite stands, apart from the others and below the background.
  SPRITES_AT = { walk: [16, 40], turn: [64, 40], leap: [16, 80] }.freeze

  # A cell of the Genesis's map: tile 0 to 10, mirrored 11, upside down 12, bank 13 and 14, priority 15.
  CELL = ->(tile, mirrored: false, upside_down: false) { tile | (mirrored ? 1 << 11 : 0) | (upside_down ? 1 << 12 : 0) | (1 << 15) }
  # The background, four cells to a row: tiles the poses draw too, one of them shown again mirrored.
  MAP = [[2, {}], [2, { mirrored: true }], [3, { upside_down: true }], [1, {}],
         [9, {}], [10, { mirrored: true, upside_down: true }], [0, {}], [7, {}]].freeze
  MAP_ACROSS = 4

  COLORS_AT = 0x40
  MAP_AT = 0x80
  FRAMES_AT = 0x100
  TILES_AT = 0x200

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  private def shared_slot_original(folder)
    tiles = TILES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    colors = MadeUpOriginalLayouts::LEVELS.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
    frames = FRAME_BYTES.values.join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[COLORS_AT, colors.bytesize] = colors
    copy[MAP_AT, MAP.length * 2] = MAP.map { |tile, turn| CELL.(tile, **turn) }.pack("n*")
    copy[FRAMES_AT, frames.bytesize] = frames
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game: the background and a sprite for each pose, all from the slot :video, and a loop that
  # only waits. +more+, handed the pack, declares what else a test wants before the loop.
  private def shared_slot_game(folder, &more)
    from = shared_slot_original(folder)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :map, at: MAP_AT, count: MAP.length, width: :half, signed: false
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.values.sum(&:bytesize), width: :byte, signed: false
        slots.colors :palette, at: COLORS_AT, count: 16
      end
      background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: MAP_ACROSS, cell: 8
      POSES.each_key do |name|
        image name, tiles: pack[:video], frame: pack[:frames].frame(FRAMES_AT_OF.fetch(name), layout: FRAME), origin: ORIGIN,
                    colors: pack[:palette]
        sprite name, at: SPRITES_AT.fetch(name)
      end
      instance_exec(pack, &more) if more
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end
end

# The picture, on every lowering: each console lays the slot's tiles out its own way, and all of
# them show what the made-up data says.
class TestPackPosesSharingTiles < Minitest::Test
  include SharedSlotTilesGame

  def test_each_pose_shows_its_pieces_where_the_frame_puts_them
    Dir.mktmpdir do |folder|
      screen = game_player.run(shared_slot_game(folder), frames: 4).screen

      POSES.each do |name, pieces|
        left, top = SPRITES_AT.fetch(name)
        assert_equal pose_pixels(pieces), pixels_read(screen, left, top, 40, 32), "the pose :#{name}"
      end
    end
  end

  # A pose the game mirrors is the frame's pieces the other way round, each in its place from the
  # picture's other edge. :leap's pieces reach 28 pixels, so its picture is 32 wide.
  def test_a_mirrored_pose_shows_its_pieces_the_other_way_round
    Dir.mktmpdir do |folder|
      program = shared_slot_game(folder) { |_pack| sprite mirror(:leap), at: [80, 80] }
      screen = game_player.run(program, frames: 4).screen
      expected = pose_pixels(POSES.fetch(:leap)).each_slice(40).flat_map { |row| row.first(32).reverse }

      assert_equal expected, pixels_read(screen, 80, 80, 32, 32)
    end
  end

  def test_the_background_shows_each_cell_turned_as_its_word_says
    Dir.mktmpdir do |folder|
      screen = game_player.run(shared_slot_game(folder), frames: 4).screen

      MAP.each_with_index do |(tile, turn), cell|
        left = (cell % MAP_ACROSS) * 8
        top = (cell / MAP_ACROSS) * 8
        shown = Piece.new(x: 0, y: 0, columns: 1, rows: 1, tile: tile, **turn)
        expected = (0...64).map { |at| BANK.fetch(shown.place_at(0, 0, at % 8, at / 8)) }
        assert_equal expected, pixels_read(screen, left, top, 8, 8), "cell #{cell} of the background"
      end
    end
  end

  private

  # The pixels of the box +width+ by +height+ whose top left is (+left+, +top+), row by row.
  def pixels_read(screen, left, top, width, height)
    (0...height).flat_map { |y| (0...width).map { |x| screen.pixel(left + x, top + y) } }
  end

  # What a box of 40 by 32 shows of a sprite of +pieces+ standing at its top left: each piece's
  # tiles in the bank's colours, and black, the backdrop, wherever no piece draws.
  def pose_pixels(pieces)
    box = Array.new(32) { Array.new(40, 0) }
    pieces.reverse_each do |piece|
      (0...(piece.rows * 8)).each do |y|
        (0...(piece.columns * 8)).each do |x|
          place = piece.place_at(x / 8, y / 8, x % 8, y % 8)
          box[ORIGIN[1] + piece.y + y][ORIGIN[0] + piece.x + x] = BANK.fetch(place) unless place.zero?
        end
      end
    end
    box.flatten
  end
end
