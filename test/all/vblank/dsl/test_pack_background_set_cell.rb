# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "differential"

# MADE-UP ORIGINALS WHOSE SCREEN HAS A FONT BESIDE ITS PICTURE, in the layout of the console each
# is for, and the games that write the font's cells onto the screen with `set_cell`. Each game is
# handed back with the pack file its build made (nil for a build that leaves its pack out), so the
# same games are played with the pack left out (test/pack_background_set_cell_at_start_tests.rb).
module PackBackgroundSetCellGames
  # Four colours a tile, so the Game Boy Color can show every tile here too.
  BLANK = Array.new(64, 0).freeze
  ART_A = (0...64).map { |at| ((at % 8) + (2 * (at / 8))) % 4 }.freeze
  ART_B = (0...64).map { |at| (at / 8).even? ? 1 + ((at % 8) / 3) : 3 }.freeze
  # The font: no place see-through, and neither reads the same back to front or upside down.
  FONT_A = (0...64).map { |at| at % 8 < 2 ? 3 : (at / 8 < 3 ? 1 : 2) }.freeze
  FONT_B = (0...64).map { |at| 1 + ((((at % 8) * 2) + (at / 8)) % 3) }.freeze
  # Tiles 0 to 2 are the picture's, 3 and 4 the font's letters and 5 the font's space.
  PLACES = [BLANK, ART_A, ART_B, FONT_A, FONT_B, BLANK].freeze
  FIRST_FONT_TILE = 3

  BANKS = [MadeUpOriginalLayouts::PALETTE, MadeUpOriginalLayouts::PALETTE.rotate(7)].freeze

  # The Advance keeps a tile two pixels a byte, the left one in the low half.
  LOW_HALF_FIRST = ->(places) { places.each_slice(2).map { |left, right| left | (right << 4) }.pack("C*") }

  # A cell of the Advance's map: tile in bits 0 to 9, mirrored 10, upside down 11, bank 12 to 15.
  ADVANCE_CELL = ->(tile, bank: 0, mirrored: false, upside_down: false) do
    tile | (mirrored ? 1 << 10 : 0) | (upside_down ? 1 << 11 : 0) | (bank << 12)
  end
  # A cell of the Super Nintendo's: tile 0 to 9, bank 10 to 12, priority 13, mirrored 14, upside down 15.
  SNES_CELL = ->(tile, bank: 0, mirrored: false, upside_down: false) do
    tile | (bank << 10) | (1 << 13) | (mirrored ? 1 << 14 : 0) | (upside_down ? 1 << 15 : 0)
  end
  # A cell of the Genesis's: tile 0 to 10, mirrored 11, upside down 12, bank 13 and 14, priority 15.
  GENESIS_CELL = ->(tile, bank: 0, mirrored: false, upside_down: false) do
    tile | (mirrored ? 1 << 11 : 0) | (upside_down ? 1 << 12 : 0) | (bank << 13) | (1 << 15)
  end
  # The Genesis keeps its colours in nine bits, high byte first; BANKS are levels it shows exactly.
  GENESIS_COLORS = lambda do |levels|
    levels.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
  end

  TILES_AT = 0x100
  COLORS_AT = 0x40
  MAP_AT = 0x20

  # The picture's map, four cells to a row: the cell at (2, 1) draws nothing.
  MAP_TILES = [[1, 2, 1, 2], [2, 1, 0, 1]].freeze

  # The Super Nintendo original's video memory: a cell of 16x16 pixels is the four tiles t, t + 1,
  # t + 16 and t + 17. Its picture's cell is tile 0 and its font's letter tile 2.
  SNES_VIDEO = Array.new(20) { BLANK }.tap do |video|
    video[0] = ART_A
    video[1] = ART_B
    video[16] = ART_B
    video[17] = ART_A
    video[2] = FONT_A
    video[3] = FONT_B
    video[18] = FONT_B
    video[19] = FONT_A
  end.freeze

  # A MADE-UP ORIGINAL KEEPING ITS SCREEN AS THE GAME BOY COLOR DOES, two maps of a byte a cell: the
  # tile in its bank of video memory, and the attributes, written here from the Color's hardware
  # (the bank of four colours in bits 0 to 2, the bank of video memory in bit 3). Video bank 0
  # holds the picture's tiles and bank 1 the font, so a font tile is a tile past 255 of the slot.
  # Its colours are each of BANKS's first four, so the screen is the Advance's, pixel for pixel.
  MAP_CELLS_BANK_TILES = 256
  MAP_CELLS_VIDEO = [*PLACES.first(FIRST_FONT_TILE), *Array.new(MAP_CELLS_BANK_TILES - FIRST_FONT_TILE, BLANK),
                     *PLACES.drop(FIRST_FONT_TILE)].freeze
  # The font's first letter in the record's terms: video bank 1's first tile, in bank 1 of colours.
  MAP_CELLS_FONT = VBlank::Original::MapCell.number(tile: MAP_CELLS_BANK_TILES, bank: 1)
  MAP_CELLS_TILE_MAP_AT = 0x20
  MAP_CELLS_ATTRIBUTES_AT = 0x30
  MAP_CELLS_PALETTE = BANKS.flat_map { |bank| bank.first(4) }.freeze

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # The made-up Color-layout original, for +platform+ (:gbc, or :pc for a computer game kept in
  # the Color's layout).
  private def map_cells_original(folder, platform)
    copy = "\0".b * (TILES_AT + (MAP_CELLS_VIDEO.length * 16))
    cells = MAP_TILES.flatten
    copy[MAP_CELLS_TILE_MAP_AT, cells.length] = cells.pack("C*")
    copy[COLORS_AT, MAP_CELLS_PALETTE.length * 2] = MAP_CELLS_PALETTE.pack("v*")
    copy[TILES_AT, MAP_CELLS_VIDEO.length * 16] = MAP_CELLS_VIDEO.map(&MadeUpOriginalLayouts::TWO_PLANES).join
    path = File.join(folder, "made_up_cells.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing the Color-layout original through a map of map cells, which its unpacking
  # writes from the two maps as a port does, told +set_cells+, and whatever the block does with it.
  private def map_cells_game_and_file(folder, platform, set_cells:, options: nil, &more)
    from = map_cells_original(folder, platform)
    layout = platform == :pc ? { layout: :gbc } : {}
    cells = MAP_TILES.flatten.length
    b = options ? VBlank::Builder.new(options: options) : VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: MAP_CELLS_VIDEO.length, **layout
        slots.colors :palette, at: COLORS_AT, count: MAP_CELLS_PALETTE.length, **layout
        slots.map_cells :map, count: cells
        slots.fill_from_copy do |copy, filled|
          repeat(cells) do |at|
            attributes = copy.byte(MAP_CELLS_ATTRIBUTES_AT + at)
            filled[:map].write_cell(at, tile: copy.byte(MAP_CELLS_TILE_MAP_AT + at) + (((attributes >> 3) & 1) * MAP_CELLS_BANK_TILES),
                                        bank: attributes & 7, mirrored: attributes >> 5, upside_down: attributes >> 6)
          end
        end
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4, set_cells: set_cells
      instance_exec(world, &more) if more
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # THE GAME OF THE TESTS on the Color-layout original, its cells in the record's terms: the font's
  # three cells told as a range of record numbers, or with +records+ as a list of
  # Original::MapCell::Cell, the cells written in the game given as Cells too, a worked-out
  # letter's Cell holding the tile the game works out.
  private def map_cells_text_game(folder, platform, records: false, blank_at: 99, options: nil)
    cell = ->(at) { VBlank::Original::MapCell::Cell.new(tile: at + MAP_CELLS_BANK_TILES, bank: 1) }
    told = records ? Array.new(3, &cell) : MAP_CELLS_FONT..(MAP_CELLS_FONT + 2)
    written = records ? { letter: cell.(0), space: cell.(2), worked: cell } : {}
    map_cells_game_and_file(folder, platform, set_cells: told, options: options) do |world|
      PackBackgroundSetCellGames.emit_text_loop(self, world, MAP_CELLS_FONT, blank_at, **written)
    end
  end

  # The game of the tests on the Advance original: the same screen, in the Advance's layout.
  private def advance_text_game(folder, **settings)
    words = MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }
    base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
    from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
    text_game(from, PLACES.length, words, base, base..(base + 2), **settings)
  end

  # A made-up original for +platform+: +tiles+ (bytes) at TILES_AT, the two banks at COLORS_AT and
  # +words+, the map, at MAP_AT.
  private def original(folder, platform, tiles, words)
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    genesis = platform == :genesis
    levels = MadeUpOriginalLayouts::LEVELS
    copy[COLORS_AT, 64] = genesis ? GENESIS_COLORS.(levels + levels.rotate(7)) : BANKS.flatten.pack("v*")
    copy[MAP_AT, words.length * 2] = words.pack(genesis ? "n*" : "v*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: platform,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game showing one background from the pack, told +set_cells+, and whatever the block does
  # with it, and the pack file its build made. +options+ are the builder's.
  private def pack_game_and_file(from, tile_count, words, across:, cell: 8, set_cells: nil, options: nil, &more)
    b = options ? VBlank::Builder.new(options: options) : VBlank::Builder.new
    told = set_cells ? { set_cells: set_cells } : {}
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: tile_count, colors: 16
        slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: across, cell: cell, **told
      instance_exec(world, &more) if more
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  private def pack_game(...) = pack_game_and_file(...).first

  # THE GAME OF THE TESTS: on its second pass it writes the font's first letter over the picture at
  # (1, 1), written in the game, and its second into the empty cell at (2, 1), worked out from a
  # table and a base as the original works its text out. On pass +blank_at+ it writes the font's
  # space into both. The cell at (0, 0) is written a number the background was not told.
  private def text_game(from, tiles, words, base, set_cells, blank_at: 99, options: nil)
    pack_game_and_file(from, tiles, words, across: 4, set_cells: set_cells, options: options) do |world|
      PackBackgroundSetCellGames.emit_text_loop(self, world, base, blank_at)
    end
  end

  # The loop of the game of the tests, on +builder+: +letter+ and +space+ are the cells written in
  # the game, the font's first letter and its space, and +base+ the font's first cell as a number,
  # to which the letters worked out from the table are added.
  # +worked+ makes the cell of a letter the game works out, given the letter's number.
  def self.emit_text_loop(builder, world, base, blank_at, letter: base, space: base + 2, worked: ->(at) { base + at })
    builder.instance_eval do
      letters = table :letters, [0, 1, 2, 9]
      pass = var :pass, 0
      game_loop do
        wait_vblank
        pass += 1
        if pass == 2
          world.set_cell 1, 1, letter
          world.set_cell 2, 1, worked.(letters[1])
          world.set_cell 0, 0, worked.(letters[3])
        end
        if pass == blank_at
          world.set_cell 1, 1, space
          world.set_cell 2, 1, worked.(letters[2])
        end
      end
    end
  end

  # The game of the tests on the Genesis original, the font's three cells told as a range.
  private def genesis_text_game(folder, **settings)
    words = MAP_TILES.flatten.map { |tile| GENESIS_CELL.(tile) }
    base = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
    from = original(folder, :genesis, PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join, words)
    text_game(from, PLACES.length, words, base, base..(base + 2), **settings)
  end

  # The Advance's layout, the cells told as a list, one of them a letter back to front and upside
  # down: on its second pass the game writes the second letter at (2, 1), and the turned one, kept
  # in a variable, at (3, 0).
  private def advance_turned_cell_game(folder, options: nil)
    words = MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }
    base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
    turned = ADVANCE_CELL.(FIRST_FONT_TILE, mirrored: true, upside_down: true)
    from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
    pack_game_and_file(from, PLACES.length, words, across: 4, set_cells: [base, base + 1, turned], options: options) do |world|
      which = var :which, turned
      pass = var :pass, 0
      game_loop do
        wait_vblank
        pass += 1
        if pass == 2
          world.set_cell 2, 1, base + 1
          world.set_cell pass + 1, 0, which
        end
      end
    end
  end

  # The Super Nintendo's layout with cells of 16x16 pixels: on its second pass the game writes the
  # letter mirrored at (0, 0), written in the game, and the letter in the other bank, kept in a
  # variable, at (1, 0).
  private def snes_big_cell_game(folder, options: nil)
    words = [SNES_CELL.(0), SNES_CELL.(0)]
    letter = SNES_CELL.(2, bank: 1)
    turned = SNES_CELL.(2, mirrored: true)
    from = original(folder, :snes, SNES_VIDEO.map(&MadeUpOriginalLayouts::FOUR_PLANES).join, words)
    pack_game_and_file(from, 20, words, across: 2, cell: 16, set_cells: [letter, turned], options: options) do |world|
      which = var :which, letter
      pass = var :pass, 0
      game_loop do
        wait_vblank
        pass += 1
        if pass == 2
          world.set_cell 0, 0, turned
          world.set_cell pass - 1, pass - 2, which
        end
      end
    end
  end

  # A game showing the Genesis original with the cells +told+, which on its second pass writes each
  # of +numbers+, read from a table, into the cells of the top row from the left.
  private def numbered_game(folder, told, numbers, options: nil)
    words = MAP_TILES.flatten.map { |tile| GENESIS_CELL.(tile) }
    from = original(folder, :genesis, PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join, words)
    pack_game_and_file(from, PLACES.length, words, across: 4, set_cells: told, options: options) do |world|
      line = table :line, numbers
      pass = var :pass, 0
      at = var :at, 0
      game_loop do
        wait_vblank
        pass += 1
        if pass == 2
          at = 0
          while at < numbers.length
            world.set_cell at, 0, line[at]
            at += 1
          end
        end
      end
    end
  end

  # A background a scene declares, written by a line of that scene, as the title screen of a port is.
  private def scene_text_game(folder, options: nil)
    words = MAP_TILES.flatten.map { |tile| GENESIS_CELL.(tile) }
    base = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
    from = original(folder, :genesis, PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join, words)
    b = options ? VBlank::Builder.new(options: options) : VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: PLACES.length, colors: 16
        slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      letters = table :letters, [0, 1]
      var :state, 0
      pass = var :pass, 0
      scene :title do
        face = background :face, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4,
                                 set_cells: base..(base + 1)
        if pass == 2
          face.set_cell 1, 1, base
          face.set_cell 2, 1, base + letters[1]
        end
      end
      game_loop do
        wait_vblank
        pass += 1
        case_var(:state) { when_val 0, :title }
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  # A game showing the Advance original, its background given +told+ and whatever the block does.
  private def advance_game(folder, **told, &more)
    words = MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }
    from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
    pack_game(from, PLACES.length, words, across: 4, **told, &more)
  end
end

# A CELL OF A BACKGROUND FROM THE DATA PACK WRITTEN AS THE ORIGINAL'S OWN CELL NUMBER
# (DSL::Background#set_cell), on a made-up original in the layout of the console it is for.
#
# A retail game puts words on a screen by storing font cells in the map its picture is in. The
# font's tiles are in video memory beside the picture's and no cell of the map names one until
# then. So the background is told the cells it may be written (`set_cells:`), and the answer key
# is the made-up data: the cell must show the font tile's places in its bank's colours, turned
# as the cell number says, and every other cell must show what the map held.
class TestPackBackgroundSetCell < Minitest::Test
  include Differential
  include PackBackgroundSetCellGames

  private def assert_cell(screen, places, at_x, at_y, bank, side: 8, mirrored: false, upside_down: false)
    side.times do |y|
      side.times do |x|
        place = places.fetch(((upside_down ? side - 1 - y : y) * side) + (mirrored ? side - 1 - x : x))
        next if place.zero?

        assert_equal BANKS.fetch(bank).fetch(place), screen.pixel(at_x + x, at_y + y),
                     "the pixel at (#{x}, #{y}) of the cell at (#{at_x}, #{at_y})"
      end
    end
  end

  # Every pixel of the 8x8 cell at (+at_x+, +at_y+) shows what is behind the background.
  private def assert_cell_empty(screen, at_x, at_y)
    behind = screen.pixel(100, 100)
    64.times do |at|
      assert_equal behind, screen.pixel(at_x + (at % 8), at_y + (at / 8)), "the pixel #{at} of the empty cell at (#{at_x}, #{at_y})"
    end
  end

  # The cells no line writes, and the one written a number the background was not told.
  private def assert_picture_unchanged(screen)
    assert_cell(screen, ART_A, 0, 0, 0)
    assert_cell(screen, ART_B, 8, 0, 0)
    assert_cell(screen, ART_A, 16, 0, 0)
    assert_cell(screen, ART_B, 0, 8, 0)
    assert_cell(screen, ART_A, 24, 8, 0)
  end

  def test_a_genesis_originals_font_cells_show_once_written
    Dir.mktmpdir do |folder|
      screen = game_player.run(genesis_text_game(folder).first, frames: 5).screen

      assert_cell(screen, FONT_A, 8, 8, 1)
      assert_cell(screen, FONT_B, 16, 8, 1)
      assert_picture_unchanged(screen)
    end
  end

  def test_a_genesis_originals_font_cells_are_gone_once_blanked
    Dir.mktmpdir do |folder|
      screen = game_player.run(genesis_text_game(folder, blank_at: 4).first, frames: 8).screen

      assert_cell_empty(screen, 8, 8)
      assert_cell_empty(screen, 16, 8)
      assert_picture_unchanged(screen)
    end
  end

  # --- the console draws the same thing ---

  def test_both_backends_agree_once_the_cells_are_written
    Dir.mktmpdir { |folder| assert_backends_agree(genesis_text_game(folder).first, frames: 5) }
  end

  def test_both_backends_agree_once_the_cells_are_blanked
    Dir.mktmpdir { |folder| assert_backends_agree(genesis_text_game(folder, blank_at: 4).first, frames: 8) }
  end

  def test_the_picture_is_as_the_map_held_it_before_a_cell_is_written
    Dir.mktmpdir do |folder|
      screen = game_player.run(genesis_text_game(folder).first, frames: 1).screen

      assert_cell(screen, ART_A, 8, 8, 0)
      assert_cell_empty(screen, 16, 8)
      assert_picture_unchanged(screen)
    end
  end

  # The Advance's layout, the cells told as a list, one of them a letter back to front.
  def test_an_advance_originals_cells_are_told_as_a_list_and_show_their_turn
    Dir.mktmpdir do |folder|
      screen = game_player.run(advance_turned_cell_game(folder).first, frames: 5).screen

      assert_cell(screen, FONT_B, 16, 8, 1)
      assert_cell(screen, FONT_A, 24, 0, 0, mirrored: true, upside_down: true)
      assert_picture_unchanged(screen)
    end
  end

  # A Super Nintendo cell of 16x16 pixels is the four tiles t, t + 1, t + 16 and t + 17 of its video
  # memory, so writing one writes all four, turned as one cell.
  def test_a_super_nintendo_originals_big_cell_is_written_whole
    Dir.mktmpdir do |folder|
      screen = game_player.run(snes_big_cell_game(folder).first, frames: 5).screen
      big = Array.new(16) do |y|
        Array.new(16) { |x| SNES_VIDEO.fetch(2 + ((y / 8) * 16) + (x / 8)).fetch(((y % 8) * 8) + (x % 8)) }
      end.flatten

      assert_cell(screen, big, 0, 0, 0, side: 16, mirrored: true)
      assert_cell(screen, big, 16, 0, 1, side: 16)
    end
  end

  # The font's two letters are told and its space, between them in the original's numbers, is not:
  # a number in the gap, one below the lowest told and one above the highest leave their cells alone.
  def test_a_number_in_a_gap_of_the_told_cells_and_one_outside_them_leave_the_cell_alone
    Dir.mktmpdir do |folder|
      first = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
      told = [first, first + 2]
      program, = numbered_game(folder, told, [first + 2, first + 1, first - 1, first + 3])
      screen = game_player.run(program, frames: 5).screen

      assert_cell_empty(screen, 0, 0)
      assert_cell(screen, ART_B, 8, 0, 0)
      assert_cell(screen, ART_A, 16, 0, 0)
      assert_cell(screen, ART_B, 24, 0, 0)
      assert_cell(screen, ART_B, 0, 8, 0)
    end
  end

  # Told cells far apart in the original's numbers: a letter, the same letter back to front, and
  # one from the other bank of colours. A number between two of them leaves its cell alone.
  def test_told_cells_far_apart_each_show_their_own_tile
    Dir.mktmpdir do |folder|
      plain = GENESIS_CELL.(FIRST_FONT_TILE)
      turned = GENESIS_CELL.(FIRST_FONT_TILE, mirrored: true)
      other_bank = GENESIS_CELL.(FIRST_FONT_TILE + 1, bank: 1)
      program, = numbered_game(folder, [other_bank, plain, turned], [turned, other_bank, plain + 0x400, plain])
      screen = game_player.run(program, frames: 5).screen

      assert_cell(screen, FONT_A, 0, 0, 0, mirrored: true)
      assert_cell(screen, FONT_B, 8, 0, 1)
      assert_cell(screen, ART_A, 16, 0, 0)
      assert_cell(screen, FONT_A, 24, 0, 0)
    end
  end

  # The Genesis keeps bit 15 of a cell for itself, so a number that differs from a told one only
  # there is the same cell.
  def test_a_number_differing_only_in_the_consoles_own_bit_is_the_told_cell
    Dir.mktmpdir do |folder|
      first = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
      program, = numbered_game(folder, first..(first + 1), [first & 0x7FFF, (first + 1) & 0x7FFF])
      screen = game_player.run(program, frames: 5).screen

      assert_cell(screen, FONT_A, 0, 0, 1)
      assert_cell(screen, FONT_B, 8, 0, 1)
      assert_cell(screen, ART_A, 16, 0, 0)
    end
  end

  # A background a scene declares is written by a line of that scene, as the title screen of a
  # port is.
  def test_a_scenes_background_is_written_from_the_scene
    Dir.mktmpdir do |folder|
      screen = game_player.run(scene_text_game(folder).first, frames: 6).screen

      assert_cell(screen, FONT_A, 8, 8, 1)
      assert_cell(screen, FONT_B, 16, 8, 1)
      assert_picture_unchanged(screen)
    end
  end

  # A MAP OF MAP CELLS (Original::MapCell), which a port of a Color game or a computer game writes
  # from its original's maps, is written in the record's terms: the same text on the same picture
  # shows cell for cell as the Advance original's, whose cells are its console's own numbers.
  def test_text_written_on_a_map_of_map_cells_of_a_color_original_shows_as_the_advances
    assert_map_cells_text_shows_as_the_advances(:gbc)
  end

  def test_text_written_on_a_map_of_map_cells_of_a_computer_original_shows_as_the_advances
    assert_map_cells_text_shows_as_the_advances(:pc)
  end

  private def assert_map_cells_text_shows_as_the_advances(platform)
    Dir.mktmpdir do |folder|
      expected = game_player.run(advance_text_game(folder).first, frames: 5).screen.to_a

      assert_equal expected, game_player.run(map_cells_text_game(folder, platform).first, frames: 5).screen.to_a
    end
  end

  def test_text_blanked_on_a_map_of_map_cells_shows_as_the_advances
    Dir.mktmpdir do |folder|
      expected = game_player.run(advance_text_game(folder, blank_at: 4).first, frames: 8).screen.to_a

      assert_equal expected, game_player.run(map_cells_text_game(folder, :gbc, blank_at: 4).first, frames: 8).screen.to_a
    end
  end

  # The cells told and written as Original::MapCell::Cell records, not numbers.
  def test_cells_given_as_map_cell_records_show_as_the_advances
    Dir.mktmpdir do |folder|
      expected = game_player.run(advance_text_game(folder, blank_at: 4).first, frames: 3).screen.to_a
      blanked = game_player.run(advance_text_game(folder, blank_at: 4).first, frames: 8).screen.to_a
      program, = map_cells_text_game(folder, :gbc, records: true, blank_at: 4)

      assert_equal expected, game_player.run(program, frames: 3).screen.to_a
      assert_equal blanked, game_player.run(program, frames: 8).screen.to_a
    end
  end

  def test_a_map_cell_record_on_a_background_of_the_consoles_own_cells_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        advance_game(folder, set_cells: [VBlank::Original::MapCell::Cell.new(tile: 3)])
      end

      assert_includes error.message, "map cell"
    end
  end

  def test_a_number_past_a_map_cell_record_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { map_cells_game_and_file(folder, :gbc, set_cells: [0x0400_0000]) }

      assert_includes error.message, "set_cells:"
    end
  end

  def test_a_map_cell_record_with_a_tile_past_its_field_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        map_cells_game_and_file(folder, :gbc, set_cells: [VBlank::Original::MapCell::Cell.new(tile: 70_000)])
      end

      assert_includes error.message, "70000"
    end
  end

  def test_a_map_cell_record_the_background_was_not_told_is_refused_where_it_is_written
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        map_cells_game_and_file(folder, :gbc, set_cells: MAP_CELLS_FONT..(MAP_CELLS_FONT + 1)) do |world|
          world.set_cell 0, 0, VBlank::Original::MapCell::Cell.new(tile: 1, bank: 1)
        end
      end

      assert_includes error.message, "set_cells:"
      assert_includes error.message, "tile 1"
    end
  end

  # Read without its high bits, the number would be a told cell: it is refused, not written as one.
  def test_a_number_past_the_record_written_in_the_game_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        map_cells_game_and_file(folder, :gbc, set_cells: [MAP_CELLS_FONT]) { |world| world.set_cell 0, 0, MAP_CELLS_FONT | 0x0400_0000 }
      end

      assert_includes error.message, "set_cells:"
    end
  end

  def test_a_cell_number_the_background_was_not_told_is_refused_where_it_is_written
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        advance_game(folder, set_cells: [ADVANCE_CELL.(3)]) { |world| world.set_cell 0, 0, ADVANCE_CELL.(4) }
      end

      assert_includes error.message, "set_cells:"
      assert_includes error.message, "0x0004"
    end
  end

  def test_a_background_told_no_cells_refuses_set_cell
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { advance_game(folder) { |world| world.set_cell 0, 0, ADVANCE_CELL.(1) } }

      assert_includes error.message, "set_cells:"
    end
  end

  def test_cells_that_are_not_cell_numbers_are_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { advance_game(folder, set_cells: ["A"]) }

      assert_includes error.message, "set_cells:"
    end
  end

  def test_a_told_cell_drawing_a_tile_past_the_slot_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { advance_game(folder, set_cells: [ADVANCE_CELL.(40)]) }

      assert_includes error.message, "tile 40"
    end
  end

  def test_a_background_of_the_games_own_tiles_refuses_set_cells
    b = Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        image(:wall, "#" => :red) { SOLID_TILE }
        tiles :walls, "#" => :wall
        background :room, tiles: :walls, map: ["##"], set_cells: [1]
      end
    end

    assert_includes error.message, "set_cells:"
  end

  # Such a background told no cells has none `set_cell` can write, whichever way it is built.
  def test_a_background_read_as_the_game_starts_told_no_cells_refuses_set_cell
    Dir.mktmpdir do |folder|
      options = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
      error = assert_raises(ArgumentError) do
        advance_game(folder, options: options) { |world| world.set_cell 0, 0, ADVANCE_CELL.(1) }
      end

      assert_includes error.message, "set_cells:"
    end
  end
end
