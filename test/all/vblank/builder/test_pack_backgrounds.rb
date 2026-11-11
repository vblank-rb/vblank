# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "made_up_original_layouts"

# A BACKGROUND DRAWN FROM THE ORIGINAL'S OWN TILES, MAP AND COLOURS (Builder::PackBackgrounds), read
# from a made-up original in the layout of the console it is for. The answer key is the made-up
# data itself: each cell of the map names a tile, a bank of colours and a turn, and the screen must
# show that tile's places in that bank's colours, turned that way.
class TestPackBackgrounds < Minitest::Test
  # Four colours a tile, so the Game Boy Color can show every tile here too.
  PLACES = [
    Array.new(64, 0),                                                     # tile 0: draws nothing
    (0...64).map { |at| ((at % 8) + (2 * (at / 8))) % 4 },                # tile 1: no row reads the same both ways
    (0...64).map { |at| (at / 8).even? ? 1 + ((at % 8) / 3) : 3 },        # tile 2: no column reads the same up and down
    (0...64).map { |at| at % 8 < 4 ? 2 : 1 }                              # tile 3
  ].freeze
  # Two banks of sixteen colours: each place a colour of its own in each bank, every one a colour
  # the Genesis shows exactly.
  BANKS = [MadeUpOriginalLayouts::PALETTE, MadeUpOriginalLayouts::PALETTE.rotate(7)].freeze
  OTHER = MadeUpOriginalLayouts::PALETTE.rotate(3)
  LATER = MadeUpOriginalLayouts::PALETTE.rotate(5)

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

  # A made-up original for +platform+: +tiles+ (bytes) at TILES_AT, the two banks at COLORS_AT and
  # +words+, the map, at MAP_AT. Hands back the Original::Game and the slots' sizes.
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

  # A game showing one background from the pack, +across+ cells to a row, each +cell+ pixels square.
  private def pack_game(from, tile_count, words, across:, cell:, colors: 16, &more)
    b = Builder.new
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: tile_count, colors: colors
        slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: across, cell: cell
      instance_exec(world, &more) if more
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The colour at (x, y) of a cell drawn from +places+ (rows of +side+) in +bank+, turned as asked.
  private def cell_color(places, side, x, y, bank, mirrored: false, upside_down: false)
    x = side - 1 - x if mirrored
    y = side - 1 - y if upside_down
    BANKS.fetch(bank).fetch(places.fetch((y * side) + x))
  end

  private def assert_cell(screen, places, side, at_x, at_y, bank, **turn)
    side.times do |y|
      side.times do |x|
        place = places.fetch(((upside(y, side, turn) * side) + across(x, side, turn)))
        next if place.zero?

        assert_equal cell_color(places, side, x, y, bank, **turn), screen.pixel(at_x + x, at_y + y),
                     "the pixel at (#{x}, #{y}) of the cell at (#{at_x}, #{at_y}), #{turn.inspect}"
      end
    end
  end

  private def upside(y, side, turn) = turn[:upside_down] ? side - 1 - y : y
  private def across(x, side, turn) = turn[:mirrored] ? side - 1 - x : x

  def test_an_advance_originals_cells_show_their_tile_bank_and_turn
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1), ADVANCE_CELL.(1, mirrored: true), ADVANCE_CELL.(2, bank: 1, upside_down: true),
               ADVANCE_CELL.(3, bank: 1, mirrored: true, upside_down: true),
               ADVANCE_CELL.(0), ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(1, bank: 1)]
      program = pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 4, cell: 8)
      screen = game_player.run(program, frames: 3).screen

      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
      assert_cell(screen, PLACES[1], 8, 8, 0, 0, mirrored: true)
      assert_cell(screen, PLACES[2], 8, 16, 0, 1, upside_down: true)
      assert_cell(screen, PLACES[3], 8, 24, 0, 1, mirrored: true, upside_down: true)
      assert_cell(screen, PLACES[1], 8, 8, 8, 0)
      assert_cell(screen, PLACES[1], 8, 24, 8, 1)
      assert_equal screen.pixel(100, 100), screen.pixel(3, 11), "a cell of tile 0, which draws nothing, shows what is behind"
    end
  end

  # A Super Nintendo cell of 16x16 pixels is the four tiles t, t + 1, t + 16 and t + 17 of its video
  # memory, and turning it turns the whole cell.
  def test_a_super_nintendo_originals_big_cells_are_four_tiles_of_its_video_memory
    Dir.mktmpdir do |folder|
      video = Array.new(18) { |at| PLACES.fetch(at % 4) }
      video[0] = PLACES[1]
      video[1] = PLACES[2]
      video[16] = PLACES[3]
      video[17] = PLACES[1]
      tiles = video.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
      words = [SNES_CELL.(0), SNES_CELL.(0, bank: 1, mirrored: true)]
      program = pack_game(original(folder, :snes, tiles, words), 18, words, across: 2, cell: 16)
      screen = game_player.run(program, frames: 3).screen
      big = Array.new(16) do |y|
        Array.new(16) { |x| video.fetch(((y / 8) * 16) + (x / 8)).fetch(((y % 8) * 8) + (x % 8)) }
      end.flatten

      assert_cell(screen, big, 16, 0, 0, 0)
      assert_cell(screen, big, 16, 16, 0, 1, mirrored: true)
    end
  end

  def test_a_genesis_originals_cells_show_their_tile_bank_and_turn
    Dir.mktmpdir do |folder|
      words = [GENESIS_CELL.(1), GENESIS_CELL.(1, mirrored: true), GENESIS_CELL.(2, bank: 1, upside_down: true),
               GENESIS_CELL.(3, bank: 1, mirrored: true, upside_down: true)]
      tiles = PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
      program = pack_game(original(folder, :genesis, tiles, words), 4, words, across: 4, cell: 8)
      screen = game_player.run(program, frames: 3).screen

      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
      assert_cell(screen, PLACES[1], 8, 8, 0, 0, mirrored: true)
      assert_cell(screen, PLACES[2], 8, 16, 0, 1, upside_down: true)
      assert_cell(screen, PLACES[3], 8, 24, 0, 1, mirrored: true, upside_down: true)
    end
  end

  # Each bank is a list of colours named for its slot, so a game draws the background with other
  # colours by place as it would one of its own.
  def test_a_bank_is_a_list_of_colours_named_for_its_slot
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)]
      other = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }
      program = pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8) do |world|
        colors :other, other
        world.draw_with({ palette_0: :other })
      end
      screen = game_player.run(program, frames: 3).screen
      place = PLACES[1][1]

      assert_equal other.fetch(place), screen.pixel(1, 0), "the pixel at (1, 0), drawn with :other in place of :palette_0"
    end
  end

  # A game showing one cell of tile 1 from bank 0, its slot of colours holding two banks, and
  # whatever the block says.
  private def game_drawn_from_bank_0(folder, &more)
    words = [ADVANCE_CELL.(1)]
    pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8, &more)
  end

  # +colors+ as a `colors` list, its first place see-through.
  private def see_through_first(colors) = colors.each_with_index.map { |color, at| at.zero? ? :transparent : color }

  # WHICH BANKS A MAP DRAWS FROM IS IN THE PLAYER'S COPY, so a game names every bank its screen
  # fades, as the original walks every bank of the console's colours, and the banks this map
  # does not use change nothing.
  def test_a_bank_the_map_does_not_use_is_stepped_with_the_ones_it_does
    Dir.mktmpdir do |folder|
      first = see_through_first(OTHER)
      second = see_through_first(LATER)
      program = game_drawn_from_bank_0(folder) do |world|
        colors :first, first
        colors :second, second
        step = var :step, 1
        world.draw_with({ palette_0: %i[first second], palette_1: %i[first second] }, showing: step)
      end
      screen = game_player.run(program, frames: 3).screen

      assert_equal second.fetch(PLACES[1][1]), screen.pixel(1, 0), "bank 0's tile at step 1, beside bank 1 that no cell uses"
    end
  end

  def test_a_background_told_only_banks_its_map_does_not_use_is_shown_as_drawn
    Dir.mktmpdir do |folder|
      other = see_through_first(OTHER)
      program = game_drawn_from_bank_0(folder) do |world|
        colors :other, other
        world.draw_with({ palette_1: :other })
      end
      screen = game_player.run(program, frames: 3).screen

      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
    end
  end

  # `recolor` of a bank the map does not use reaches what is drawn with it, a sprite here, and
  # leaves the background as drawn.
  def test_a_bank_the_map_does_not_use_is_recolored_beside_the_background
    Dir.mktmpdir do |folder|
      other = see_through_first(OTHER)
      program = game_drawn_from_bank_0(folder) do |world|
        colors :other, other
        world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
        image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
        dot = sprite :dot, at: [40, 40]
        dot.draw_with :palette_1
        recolor :palette_1, :other
      end
      screen = game_player.run(program, frames: 4).screen

      assert_equal other.fetch(2), screen.pixel(41, 41), "the sprite drawn with bank 1, which holds :other"
      assert_cell(screen, PLACES[1], 8, 0, 0, 0)
    end
  end

  def test_a_list_that_is_not_a_bank_of_the_slot_is_still_refused
    Dir.mktmpdir do |folder|
      other = see_through_first(OTHER)
      error = assert_raises(ArgumentError) do
        game_drawn_from_bank_0(folder) do |world|
          colors :other, other
          world.draw_with({ other: :palette_0 })
        end
      end

      assert_includes error.message, "none of its tiles is drawn from :other"
    end
  end

  def test_a_bank_the_map_does_not_use_drawn_with_no_list_of_colors_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        game_drawn_from_bank_0(folder) { |world| world.draw_with({ palette_1: :ghost }) }
      end

      assert_includes error.message, ":ghost, which is not a list of colors"
    end
  end

  def test_a_map_whose_cells_do_not_fill_its_rows_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)] * 6
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 4, cell: 8)
      end

      assert_includes error.message, "across:"
    end
  end

  def test_a_big_cell_of_an_original_whose_cells_are_one_tile_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)]
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 16)
      end

      assert_includes error.message, "cell:"
    end
  end

  def test_a_build_reading_its_pack_as_it_starts_is_told_it_is_not_made_yet
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, [ADVANCE_CELL.(1)])
      b = Builder.new(options: VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true))
      pack = b.data_pack(from: from, version: "1") do |slots|
        slots.tiles :video, at: TILES_AT, count: 4
        slots.numbers :map, at: MAP_AT, count: 1, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      error = assert_raises(ArgumentError) do
        b.background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 1
      end

      assert_includes error.message, "not made that way yet"
    end
  end

  def test_a_map_that_draws_nothing_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(0)] * 4
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 2, cell: 8)
      end

      assert_includes error.message, "draws nothing"
    end
  end

  def test_a_game_list_named_as_a_bank_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1)]
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
      b = Builder.new
      error = assert_raises(ArgumentError) do
        b.instance_eval do
          screen :tiled
          colors :palette_0, %i[transparent red green blue]
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: 4
            slots.numbers :map, at: MAP_AT, count: 1, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
          end
          background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 1
        end
      end

      assert_includes error.message, ":palette_0"
    end
  end

  def test_a_cell_drawing_a_tile_past_the_slot_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(9)]
      error = assert_raises(ArgumentError) do
        pack_game(original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words), 4, words, across: 1, cell: 8)
      end

      assert_includes error.message, "tile 9"
    end
  end
end
