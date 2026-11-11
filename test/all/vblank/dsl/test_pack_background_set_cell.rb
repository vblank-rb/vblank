# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "differential"

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
  # with it. +options+ are the builder's.
  private def pack_game(from, tile_count, words, across:, cell: 8, set_cells: nil, options: nil, &more)
    b = options ? Builder.new(options: options) : Builder.new
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
    b.program
  end

  # THE GAME OF THE TESTS: on its second pass it writes the font's first letter over the picture at
  # (1, 1), written in the game, and its second into the empty cell at (2, 1), worked out from a
  # table and a base as the original works its text out. On pass +blank_at+ it writes the font's
  # space into both. The cell at (0, 0) is written a number the background was not told.
  private def text_game(from, tiles, words, base, set_cells, blank_at: 99)
    pack_game(from, tiles, words, across: 4, set_cells: set_cells) do |world|
      letters = table :letters, [0, 1, 2, 9]
      pass = var :pass, 0
      game_loop do
        wait_vblank
        pass += 1
        if pass == 2
          world.set_cell 1, 1, base
          world.set_cell 2, 1, base + letters[1]
          world.set_cell 0, 0, base + letters[3]
        end
        if pass == blank_at
          world.set_cell 1, 1, base + 2
          world.set_cell 2, 1, base + letters[2]
        end
      end
    end
  end

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

  private def genesis_text_game(folder, **timing)
    words = MAP_TILES.flatten.map { |tile| GENESIS_CELL.(tile) }
    base = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
    from = original(folder, :genesis, PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join, words)
    text_game(from, PLACES.length, words, base, base..(base + 2), **timing)
  end

  def test_a_genesis_originals_font_cells_show_once_written
    Dir.mktmpdir do |folder|
      screen = game_player.run(genesis_text_game(folder), frames: 5).screen

      assert_cell(screen, FONT_A, 8, 8, 1)
      assert_cell(screen, FONT_B, 16, 8, 1)
      assert_picture_unchanged(screen)
    end
  end

  def test_a_genesis_originals_font_cells_are_gone_once_blanked
    Dir.mktmpdir do |folder|
      screen = game_player.run(genesis_text_game(folder, blank_at: 4), frames: 8).screen

      assert_cell_empty(screen, 8, 8)
      assert_cell_empty(screen, 16, 8)
      assert_picture_unchanged(screen)
    end
  end

  # --- the console draws the same thing ---

  def test_both_backends_agree_once_the_cells_are_written
    Dir.mktmpdir { |folder| assert_backends_agree(genesis_text_game(folder), frames: 5) }
  end

  def test_both_backends_agree_once_the_cells_are_blanked
    Dir.mktmpdir { |folder| assert_backends_agree(genesis_text_game(folder, blank_at: 4), frames: 8) }
  end

  def test_the_picture_is_as_the_map_held_it_before_a_cell_is_written
    Dir.mktmpdir do |folder|
      screen = game_player.run(genesis_text_game(folder), frames: 1).screen

      assert_cell(screen, ART_A, 8, 8, 0)
      assert_cell_empty(screen, 16, 8)
      assert_picture_unchanged(screen)
    end
  end

  # The Advance's layout, the cells told as a list, one of them a letter back to front.
  def test_an_advance_originals_cells_are_told_as_a_list_and_show_their_turn
    Dir.mktmpdir do |folder|
      words = MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }
      base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
      turned = ADVANCE_CELL.(FIRST_FONT_TILE, mirrored: true, upside_down: true)
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
      program = pack_game(from, PLACES.length, words, across: 4, set_cells: [base, base + 1, turned]) do |world|
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
      screen = game_player.run(program, frames: 5).screen

      assert_cell(screen, FONT_B, 16, 8, 1)
      assert_cell(screen, FONT_A, 24, 0, 0, mirrored: true, upside_down: true)
      assert_picture_unchanged(screen)
    end
  end

  # A Super Nintendo cell of 16x16 pixels is the four tiles t, t + 1, t + 16 and t + 17 of its video
  # memory, so writing one writes all four, turned as one cell.
  def test_a_super_nintendo_originals_big_cell_is_written_whole
    Dir.mktmpdir do |folder|
      video = Array.new(20) { BLANK }
      video[0] = ART_A
      video[1] = ART_B
      video[16] = ART_B
      video[17] = ART_A
      video[2] = FONT_A
      video[3] = FONT_B
      video[18] = FONT_B
      video[19] = FONT_A
      words = [SNES_CELL.(0), SNES_CELL.(0)]
      letter = SNES_CELL.(2, bank: 1)
      turned = SNES_CELL.(2, mirrored: true)
      from = original(folder, :snes, video.map(&MadeUpOriginalLayouts::FOUR_PLANES).join, words)
      program = pack_game(from, 20, words, across: 2, cell: 16, set_cells: [letter, turned]) do |world|
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
      screen = game_player.run(program, frames: 5).screen
      big = Array.new(16) do |y|
        Array.new(16) { |x| video.fetch(2 + ((y / 8) * 16) + (x / 8)).fetch(((y % 8) * 8) + (x % 8)) }
      end.flatten

      assert_cell(screen, big, 0, 0, 0, side: 16, mirrored: true)
      assert_cell(screen, big, 16, 0, 1, side: 16)
    end
  end

  # A background a scene declares is written by a line of that scene, as the title screen of a
  # port is.
  def test_a_scenes_background_is_written_from_the_scene
    Dir.mktmpdir do |folder|
      words = MAP_TILES.flatten.map { |tile| GENESIS_CELL.(tile) }
      base = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
      from = original(folder, :genesis, PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join, words)
      b = Builder.new
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
      screen = game_player.run(b.program, frames: 6).screen

      assert_cell(screen, FONT_A, 8, 8, 1)
      assert_cell(screen, FONT_B, 16, 8, 1)
      assert_picture_unchanged(screen)
    end
  end

  private def advance_game(folder, **told, &more)
    words = MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }
    from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
    pack_game(from, PLACES.length, words, across: 4, **told, &more)
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

  def test_a_build_reading_its_pack_as_it_starts_is_told_it_is_not_made_yet
    Dir.mktmpdir do |folder|
      options = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
      error = assert_raises(ArgumentError) { advance_game(folder, set_cells: [ADVANCE_CELL.(3)], options: options) }

      assert_includes error.message, "set_cells:"
      assert_includes error.message, "not made that way yet"
    end
  end

  # Such a background is told no cells, so no `set_cell` reaches one read as the game starts.
  def test_a_background_read_as_the_game_starts_refuses_set_cell
    Dir.mktmpdir do |folder|
      options = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)
      error = assert_raises(ArgumentError) do
        advance_game(folder, options: options) { |world| world.set_cell 0, 0, ADVANCE_CELL.(1) }
      end

      assert_includes error.message, "set_cells:"
    end
  end
end
