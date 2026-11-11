# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"
require "tmpdir"
require "made_up_original_layouts"

# A TITLE AS A GENESIS GAME KEEPS ONE: two dozen sprites drawn from an original's frames, each
# frame three pieces of different sizes, most of them off the grid of 8 the origin sets, in two
# orders the game works out; and a background that every eighth pass has a line of twenty letters
# written into it a cell at a time, each letter read from a table and written by one routine as
# the original's own cell number.
#
# A retail game does all of that in a frame: a piece is four words copied into the sprite table
# with the object's place added to two of them, and a letter is a word stored in the map.
module PiecePaceGames
  # Tile 0 draws nothing. Every other tile draws three colours all over and its own number in
  # its top row, a bit a pixel, so no two are alike.
  TILE = lambda do |n|
    (0...64).map do |at|
      x = at % 8
      y = at / 8
      next 0 if n.zero?

      y.zero? ? (n[x].zero? ? 5 : 4) : 1 + ((x + (2 * y) + n) % 3)
    end
  end
  ART_TILES = 48
  FONT_TILES = 84
  FIRST_FONT_TILE = ART_TILES + 1
  TILES = (0..(ART_TILES + FONT_TILES)).map(&TILE).freeze

  # A frame as a Genesis game keeps one: a word that counts its pieces, then the console's own
  # sprite entry for each.
  FRAME = VBlank::Original::FrameLayout.new(
    piece_bytes: 8, counted: true, count_bytes: 2, high_byte_first: true,
    y_at: 0, x_at: 6, position_bytes: 2, tile_at: 4, tile_bytes: 2, tile_bits: 11,
    flags_at: 4, flags_bytes: 2, mirrored_bit: 11, upside_down_bit: 12, bank_bit: 13, bank_bits: 2,
    size_at: 2, columns_bit: 2, rows_bit: 0, size_bits: 2, tile_order: :down_columns
  )

  # A piece of a frame: where its top left is from the object's place, how many tiles across and
  # down it is, its first tile, and whether it is shown back to front.
  Piece = Data.define(:x, :y, :columns, :rows, :tile, :mirrored) do
    # The eight bytes the original keeps it in: down, size, link, tile word, across.
    def bytes
      word = tile | (mirrored ? 1 << 11 : 0) | 0x8000
      [y, ((columns - 1) << 2) | (rows - 1), 0, word, x].pack("s>CCns>")
    end

    # The place at (+x+, +y+) inside the square at column +column+ and row +row+ of the piece as it is shown.
    def place_at(column, row, x, y)
      from_column = mirrored ? columns - 1 - column : column
      TILES.fetch(tile + (from_column * rows) + row)[(y * 8) + (mirrored ? 7 - x : x)]
    end
  end

  # Each shape's three pieces as [across, down, columns, rows], the one in front first.
  SHAPES = [
    [[0, -4, 2, 2], [16, -4, 1, 2], [4, 12, 3, 1]],
    [[-4, 0, 3, 2], [20, 4, 1, 1], [0, 16, 2, 1]],
    [[0, 0, 2, 3], [16, -4, 2, 1], [16, 4, 1, 2]],
    [[4, -4, 1, 1], [-4, 4, 4, 2], [8, 20, 2, 1]]
  ].freeze
  POSE_COUNT = 8
  # Eight poses, each shape twice from tiles of its own, the second time with a piece mirrored.
  POSES = (0...POSE_COUNT).to_h do |pose|
    tile = 1 + (pose * 5)
    pieces = SHAPES.fetch(pose % SHAPES.length).map do |x, y, columns, rows|
      piece = Piece.new(x: x, y: y, columns: columns, rows: rows, tile: tile, mirrored: pose >= SHAPES.length && columns == 2)
      tile += 2
      piece
    end
    [:"pose_#{pose}", pieces]
  end.freeze
  FRAME_BYTES = POSES.transform_values { |pieces| [pieces.length].pack("n") + pieces.map(&:bytes).join }.freeze
  FRAMES_AT_OF = POSES.keys.each_with_index.to_h { |name, at| [name, FRAME_BYTES.values.first(at).sum(&:bytesize)] }.freeze
  ORIGIN = [4, 4].freeze
  # The size of every pose's picture.
  BOX = [40, 32].freeze

  # The places of each pose's box, row by row: what its pieces draw, the first in front. The same
  # picture with no pieces to it.
  FLAT_PLACES = POSES.transform_values do |pieces|
    box = Array.new(BOX[1]) { Array.new(BOX[0], 0) }
    pieces.reverse_each do |piece|
      (0...(piece.rows * 8)).each do |y|
        (0...(piece.columns * 8)).each do |x|
          place = piece.place_at(x / 8, y / 8, x % 8, y % 8)
          box[ORIGIN[1] + piece.y + y][ORIGIN[0] + piece.x + x] = place unless place.zero?
        end
      end
    end
    box.flatten
  end.freeze

  SPRITES = 24
  PIECES_A_POSE = 3
  IN_AN_ORDER = 12
  LETTERS = 20
  WRITTEN_EVERY = 8

  # A cell of the Genesis's map: the tile in its low eleven bits, priority in bit 15.
  CELL = ->(tile) { tile | (1 << 15) }
  MAP_ACROSS = 64
  MAP_DOWN = 32
  MAP = Array.new(MAP_ACROSS * MAP_DOWN) { |at| CELL.((((at % MAP_ACROSS) + (at / MAP_ACROSS)) % 7).zero? ? 1 + (at % 5) : 0) }.freeze
  FONT_BASE = CELL.(FIRST_FONT_TILE)
  # The line's letters, each a place in the font's table, and the table: which cell of the font each is.
  LINE = Array.new(LETTERS) { |at| (at * 7) % 40 }.freeze
  FONT_TABLE = Array.new(40) { |at| (at * 2) + 1 }.freeze

  COLORS_AT = 0x40
  FRAMES_AT = 0x100
  MAP_AT = 0x400
  TILES_AT = MAP_AT + (MAP.length * 2)

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # The made-up original, written into +folder+.
  def self.original(folder)
    tiles = TILES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    colors = MadeUpOriginalLayouts::LEVELS.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
    frames = FRAME_BYTES.values.join
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[COLORS_AT, colors.bytesize] = colors
    copy[MAP_AT, MAP.length * 2] = MAP.pack("n*")
    copy[FRAMES_AT, frames.bytesize] = frames
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game, reading the original in +folder+ as it is built. +pieces+ draws each pose as its
  # frame's pieces; without, as one flat picture of the same pixels. The sprites stand in four rows
  # of six and sway, the first of each row +left+ pixels from the screen's edge at its nearest.
  def self.game(folder, pieces:, left: 4)
    from = original(folder)
    letters = LETTERS
    written_every = WRITTEN_EVERY
    font_base = FONT_BASE
    VBlank.game("PIECE PACE", consoles: %i[genesis]) do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :map, at: MAP_AT, count: MAP.length, width: :half, signed: false
        slots.numbers :frames, at: FRAMES_AT, count: FRAME_BYTES.values.sum(&:bytesize), width: :byte, signed: false
        slots.colors :palette, at: COLORS_AT, count: 16
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: MAP_ACROSS, cell: 8,
                                 set_cells: FONT_BASE..(FONT_BASE + FONT_TILES - 1)
      POSES.each_key do |name|
        if pieces
          image name, tiles: pack[:video], frame: pack[:frames].frame(FRAMES_AT_OF.fetch(name), layout: FRAME), origin: ORIGIN,
                      colors: pack[:palette], size: BOX
        else
          image name, width: BOX[0], height: BOX[1], colors: pack[:palette].bank(0, size: 16), places: FLAT_PLACES.fetch(name)
        end
      end
      things = Array.new(SPRITES) { |i| sprite :"thing_#{i}", at: [0, 0], facing: { down: :"pose_#{i % POSE_COUNT}" } }
      things.each_slice(IN_AN_ORDER) { |run| draw_in_order(*run) }
      line = table :line, LINE
      font = table :font, FONT_TABLE
      column = var :column, 0
      letter = var :letter, 0
      func(:put_letter) { world.set_cell column, 20, font[letter] + font_base }
      t = var :t, 0
      turn = var :turn, 0
      game_loop do
        t += 1
        things.each_with_index do |thing, i|
          thing.move_to left + ((i % 6) * 46) + ((t + (i * 11)) & 31), ((i / 6) * 52) + ((t + (i * 5)) & 15)
        end
        turn += 1
        if turn == written_every
          turn = 0
          column = 0
          while column < letters
            letter = line[column]
            call :put_letter
            column += 1
          end
        end
      end
    end
  end
end

# WHAT THAT TITLE COSTS THE GENESIS, measured in the emulator, and that it shows what the
# interpreter shows. Every pass must fit a frame, the pass that writes the line too; and pieces
# must cost about what the same pictures cost flat, since a piece is a row of the sprite table
# either way.
class TestGenesisPiecePace < Minitest::Test
  # How much of a frame the pass that writes the line may take, how much an ordinary pass may, and
  # an ordinary pass with pieces against the same pass with flat pictures. Measured, the first is
  # about a third of a frame, of which the line of letters is a third: each letter's cell is a
  # word read from a table of the told cells, not found by a test for each told cell, and the
  # loop and its table reads test and branch as a 68000 routine written by hand would. The second
  # is about a fifth, the sprites being half of it: the walk that places them keeps its place
  # in registers, a sprite wholly on the screen is two compares and two long words copied a
  # piece, and the video chip copies the table in by itself. The third is about a sixth more:
  # three rows of the table a sprite where the flat picture takes fewer.
  MOST_OF_A_FRAME = 0.34
  MOST_OF_AN_ORDINARY_FRAME = 0.23
  MOST_OVER_FLAT = 1.2

  PASSES = 32

  TAPE = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: PIECE PACE 0x00000000
    starts from: power-on
  TAPE

  def test_the_pieces_show_what_the_interpreter_shows
    Dir.mktmpdir do |folder|
      game_player.run(PiecePaceGames.game(folder, pieces: true).program(console: :genesis), frames: 12)
    end
  end

  # The first sprite of each row is partly or wholly off the screen's left, so its pieces are
  # tested one by one and noted between sprites whose pieces are copied whole.
  def test_pieces_off_the_edge_show_what_the_interpreter_shows
    Dir.mktmpdir do |folder|
      game_player.run(PiecePaceGames.game(folder, pieces: true, left: -34).program(console: :genesis), frames: 12)
    end
  end

  # Eighty sprites of one piece are every row the sprite table has.
  def test_a_full_sprite_table_shows_what_the_interpreter_shows
    game = VBlank.game("FULL TABLE", consoles: %i[genesis]) do
      screen :tiled
      image(:dot, "#" => :red, "." => :blue) { (["#.#.#..#"] * 8).join("\n") }
      dots = Array.new(80) { |i| sprite :"dot_#{i}", at: [(i % 16) * 18, (i / 16) * 20], facing: { down: :dot } }
      t = var :t, 0
      game_loop do
        t += 1
        dots.each_with_index { |dot, i| dot.move_to ((i % 16) * 18) + (t & 7), (i / 16) * 20 }
      end
    end

    game_player.run(game.program(console: :genesis), frames: 6)
  end

  def test_every_pass_fits_a_frame_and_the_line_takes_under_half_of_one
    Dir.mktmpdir do |folder|
      rom = cartridge(folder, pieces: true)
      still = rom.profile(out: StringIO.new, frames: PASSES)
      frames = rom.profile(out: StringIO.new, tape: TAPE, frames: still.measured_frames)

      assert_equal({ 1 => PASSES }, still.passes_by_frames, "every pass fits in one frame")
      assert_empty frames.held.map(&:frame), "every frame shows a new picture"
      assert_match(/put_letter|main/, frames.busiest.game.first.routine.to_s)
      assert_operator frames.busiest.awake_share, :<=, MOST_OF_A_FRAME,
                      "the pass that writes the line takes #{(frames.busiest.awake_share * 100).round(1)}% of a frame"
    end
  end

  def test_an_ordinary_pass_with_pieces_costs_about_what_flat_pictures_cost
    Dir.mktmpdir do |folder|
      with_pieces, flat = [true, false].map { |pieces| ordinary_awake_share(cartridge(folder, pieces: pieces)) }

      assert_operator with_pieces, :<=, flat * MOST_OVER_FLAT,
                      "pieces take #{(with_pieces * 100).round(1)}% of a frame and flat pictures #{(flat * 100).round(1)}%"
      assert_operator with_pieces, :<=, MOST_OF_AN_ORDINARY_FRAME,
                      "an ordinary pass takes #{(with_pieces * 100).round(1)}% of a frame"
    end
  end

  # Every piece is a row of the sprite table: the build cuts none in two and joins none.
  def test_the_profile_says_how_many_tiles_are_in_video_memory
    Dir.mktmpdir do |folder|
      out = StringIO.new
      result = cartridge(folder, pieces: true).profile(out: out, frames: 4)

      assert_equal VBlank::IR::Backends::Genesis::Art::MOST_TILES, result.video_tiles.room
      assert_operator result.video_tiles.every_screen, :>=, PiecePaceGames::FONT_TILES
      assert_operator result.video_tiles.every_screen, :<=, PiecePaceGames::TILES.length
      assert_empty result.video_tiles.by_scene
      assert_match(/Video memory holds #{result.video_tiles.every_screen} of #{result.video_tiles.room} tiles/, out.string)
    end
  end

  private

  def cartridge(folder, **how)
    PiecePaceGames.game(folder, **how).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
  end

  # How much of a frame a pass that writes no line takes: the middle one of the frames measured,
  # which the passes that write the line, one in eight, and the frames after them are above.
  def ordinary_awake_share(rom)
    still = rom.profile(out: StringIO.new, frames: PASSES)
    shares = rom.profile(out: StringIO.new, tape: TAPE, frames: still.measured_frames).readings.map(&:awake_share).sort
    shares.fetch(shares.length / 2)
  end
end
