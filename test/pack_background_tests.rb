# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original_layouts"
require "pack_at_start_tests"

# MADE-UP ORIGINALS WHOSE SCREEN IS A BACKGROUND OF THEIR OWN TILES, MAP AND COLOURS, and a game
# that shows it through a data pack (Builder::PackBackgrounds). The answer key is the made-up data
# itself: each cell of the map names a tile, a bank of colours and a turn, written here from each
# console's hardware and not from VBlank's readers.
module PackBackgroundGames
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

  constants.each { |name| Ractor.make_shareable(const_get(name)) }

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

  # A game showing one background from the pack, +across+ cells to a row, each +cell+ pixels
  # square, built as +options+ say. Hands back the program and the pack file the build made (nil
  # for a build that leaves its pack out).
  private def pack_game_and_file(from, tile_count, words, across:, cell:, colors: 16, options: VBlank::Cartridge::Options.new, &more)
    b = VBlank::Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: tile_count, colors: colors
        slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 32
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: across, cell: cell
      if more
        instance_exec(world, &more)
      else
        game_loop { wait_vblank }
      end
    end
    b.finalize_program
    [b.program, b.made_data_pack_file]
  end

  private def pack_game(...) = pack_game_and_file(...).first

  # The Advance's tiles of PLACES, as its cartridge keeps them.
  private def advance_tiles = PLACES.map(&LOW_HALF_FIRST).join
end

# A BACKGROUND FROM THE PACK, ITS PACK LEFT OUT: the same games built with `pack_at_start: true` and
# handed the pack file the all-in-one build made show what the all-in-one build shows. The answer
# key is the all-in-one build on the interpreter.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackBackgroundAtStartTests
  include PackBackgroundGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The game built both ways shows one picture after each of +frames+.
  private def assert_background_plays_alike(what, platform, tiles, tile_count, words, frames: [1, 3], **shape, &more)
    Dir.mktmpdir do |folder|
      from = original(folder, platform, tiles, words)
      whole, file = pack_game_and_file(from, tile_count, words, **shape, &more)
      left_out, = pack_game_and_file(from, tile_count, words, options: LEFT_OUT, **shape, &more)

      frames.each do |count|
        shown = game_player.run(whole, frames: count).screen.to_a
        assert_operator shown.flatten.uniq.length, :>, 2, "#{what}: the all-in-one build draws the background"
        assert_equal shown, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the game handed its pack shows what the all-in-one build shows"
      end
    end
  end

  def test_an_advance_originals_background_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(1, mirrored: true), ADVANCE_CELL.(2, bank: 1, upside_down: true),
             ADVANCE_CELL.(3, bank: 1, mirrored: true, upside_down: true),
             ADVANCE_CELL.(0), ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(1, bank: 1)]

    assert_background_plays_alike("the Advance's", :gba, advance_tiles, 4, words, across: 4, cell: 8)
  end

  def test_a_super_nintendo_originals_big_cells_read_at_start_show_as_the_all_in_one_build
    video = Array.new(19) { |at| PLACES.fetch(at % 4) }
    video[0] = PLACES[1]
    video[1] = PLACES[2]
    video[16] = PLACES[3]
    video[17] = PLACES[1]
    words = [SNES_CELL.(0), SNES_CELL.(0, bank: 1, mirrored: true), SNES_CELL.(1, upside_down: true), SNES_CELL.(1, bank: 1)]

    assert_background_plays_alike("the Super Nintendo's", :snes, video.map(&MadeUpOriginalLayouts::FOUR_PLANES).join, 19, words,
                                  across: 2, cell: 16)
  end

  def test_a_genesis_originals_background_read_at_start_shows_as_the_all_in_one_build
    words = [GENESIS_CELL.(1), GENESIS_CELL.(1, mirrored: true), GENESIS_CELL.(2, bank: 1, upside_down: true),
             GENESIS_CELL.(3, bank: 1, mirrored: true, upside_down: true)]

    assert_background_plays_alike("the Genesis's", :genesis, PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join, 4, words,
                                  across: 4, cell: 8)
  end

  # The tiles from one tile of the slot on: the map's tile 0 is the slot's tile 1.
  def test_a_background_from_one_tile_of_the_slot_on_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(0), ADVANCE_CELL.(1, bank: 1), ADVANCE_CELL.(2, mirrored: true)]
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, advance_tiles, words)
      games = [VBlank::Cartridge::Options.new, LEFT_OUT].map do |options|
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          screen :tiled
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: 4
            slots.numbers :map, at: MAP_AT, count: 3, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
          end
          background :world, tiles: pack[:video].tile(1), map: pack[:map], colors: pack[:palette], across: 3
          game_loop { wait_vblank }
        end
        b.finalize_program
        [b.program, b.made_data_pack_file]
      end
      (whole, file), (left_out,) = games

      assert_equal game_player.run(whole, frames: 2).screen.to_a, game_player.hand_file(file).run(left_out, frames: 2).screen.to_a
    end
  end

  # Each bank is a list named for its slot in a build that leaves the pack out too, so the game
  # draws the tiles of one bank with a list of its own and the other bank stays as the file has it.
  def test_a_bank_drawn_with_another_list_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, mirrored: true), ADVANCE_CELL.(1, bank: 1, upside_down: true)]
    other = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }

    assert_background_plays_alike("drawn with another list", :gba, advance_tiles, 4, words, across: 2, cell: 8) do |world|
      colors :other, other
      world.draw_with({ palette_0: :other })
      game_loop { wait_vblank }
    end
  end

  # A step picked as the game runs: each bank through lists of the game's own, then back to its own.
  def test_banks_stepped_through_lists_read_at_start_show_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3), ADVANCE_CELL.(1, bank: 1, mirrored: true)]
    lists = [3, 5, 9, 11].map { |turn| MadeUpOriginalLayouts::PALETTE.rotate(turn).each_with_index.map { |color, at| at.zero? ? :transparent : color } }

    assert_background_plays_alike("stepped lists", :gba, advance_tiles, 4, words, across: 4, cell: 8, frames: [1, 2, 3, 4, 5]) do |world|
      lists.each_with_index { |list, at| colors :"other_#{at}", list }
      step = var :step, 0
      game_loop do
        world.draw_with({ palette_0: %i[other_0 other_1], palette_1: %i[other_2 other_3] }, showing: step)
        wait_vblank
        step.store!(step + 1)
      end
    end
  end

  # Which banks the map uses is in the file, so a game names every bank its screen steps. Here
  # no cell is drawn from bank 1, and naming it changes nothing.
  def test_a_bank_the_map_does_not_use_stepped_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, mirrored: true), ADVANCE_CELL.(3)]
    lists = [OTHER, LATER].map { |list| list.each_with_index.map { |color, at| at.zero? ? :transparent : color } }

    assert_background_plays_alike("a bank no cell uses", :gba, advance_tiles, 4, words, across: 3, cell: 8, frames: [1, 2, 3, 4]) do |world|
      lists.each_with_index { |list, at| colors :"other_#{at}", list }
      step = var :step, 0
      game_loop do
        world.draw_with({ palette_0: %i[other_0 other_1], palette_1: %i[other_0 other_1] }, showing: step)
        wait_vblank
        step.store!(step + 1)
      end
    end
  end

  # Told only a bank no cell uses, the background is shown as drawn.
  def test_only_a_bank_the_map_does_not_use_drawn_with_a_list_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, mirrored: true)]
    other = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }

    assert_background_plays_alike("only a bank no cell uses", :gba, advance_tiles, 4, words, across: 2, cell: 8) do |world|
      colors :other, other
      world.draw_with({ palette_1: :other })
      game_loop { wait_vblank }
    end
  end

  # A BANK'S COLOURS ARE READ AS THE GAME STARTS, AND SO IS WHATEVER IS MADE OF THEM. Each of these
  # needs a bank's colours where a build holding them works something out: the steps of a walk, a
  # picture's pixels, a list told to hold a bank.
  WALK_STEPS = 5

  # A screen brought up from black a bank at a time, as a console's own games walk every bank of
  # their colours: each step of each walk is made from the file's colours.
  def test_banks_walked_up_from_black_read_at_start_show_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, mirrored: true), ADVANCE_CELL.(1, bank: 1, upside_down: true)]

    assert_background_plays_alike("walked from black", :gba, advance_tiles, 4, words, across: 4, cell: 8, frames: 2..(WALK_STEPS + 3)) do |world|
      walks = { palette_0: color_walk(:palette_0, from: :black, steps: WALK_STEPS),
                palette_1: color_walk(:palette_1, from: :black, steps: WALK_STEPS) }
      step = var :step, 0
      game_loop do
        world.draw_with(walks, showing: step)
        wait_vblank
        step.store!(step + 1)
      end
    end
  end

  # The fade as a game with a screen of one bank writes it: one walk, and no bank named. Which
  # bank the map uses is in the file, so the build with its pack left out draws every bank with it.
  def test_a_walk_given_alone_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1, bank: 1), ADVANCE_CELL.(2, bank: 1, mirrored: true), ADVANCE_CELL.(3, bank: 1)]

    assert_background_plays_alike("one walk", :gba, advance_tiles, 4, words, across: 3, cell: 8, frames: 2..(WALK_STEPS + 3)) do |world|
      step = var :step, 0
      game_loop do
        world.draw_with color_walk(:palette_1, from: :white, steps: WALK_STEPS), showing: step
        wait_vblank
        step.store!(step + 1)
      end
    end
  end

  def test_a_genesis_originals_bank_walked_read_at_start_shows_as_the_all_in_one_build
    words = [GENESIS_CELL.(1), GENESIS_CELL.(2, bank: 1, upside_down: true), GENESIS_CELL.(3, bank: 1, mirrored: true)]
    tiles = PLACES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join

    assert_background_plays_alike("the Genesis's, walked", :genesis, tiles, 4, words, across: 3, cell: 8, frames: 2..(WALK_STEPS + 3)) do |world|
      walks = { palette_0: color_walk(:palette_0, from: :black, steps: WALK_STEPS),
                palette_1: color_walk(:palette_1, from: :white, steps: WALK_STEPS) }
      step = var :step, 0
      game_loop do
        world.draw_with(walks, showing: step)
        wait_vblank
        step.store!(step + 1)
      end
    end
  end

  def test_a_bank_drawn_with_another_bank_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2), ADVANCE_CELL.(3, bank: 1), ADVANCE_CELL.(1, bank: 1, mirrored: true)]

    assert_background_plays_alike("one bank with another", :gba, advance_tiles, 4, words, across: 4, cell: 8) do |world|
      world.draw_with({ palette_0: :palette_1 })
      game_loop { wait_vblank }
    end
  end

  # A picture drawn in a bank's list, on a sprite beside the background.
  def test_a_picture_drawn_in_a_bank_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1)]

    assert_background_plays_alike("a picture in a bank", :gba, advance_tiles, 4, words, across: 2, cell: 8) do |_world|
      image :mark, width: 8, height: 8, colors: :palette_1, places: (0...64).map { |at| 1 + (at % 3) }
      sprite :mark, at: [40, 40]
      game_loop { wait_vblank }
    end
  end

  # `recolor` of a bank reaches what is drawn with it: a sprite, and the background's cells of
  # that bank. A list of the game's own, then another bank, then its own colours again.
  def test_a_bank_recolored_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, bank: 1, mirrored: true)]
    other = OTHER.each_with_index.map { |color, at| at.zero? ? :transparent : color }

    assert_background_plays_alike("a bank recoloured", :gba, advance_tiles, 4, words, across: 3, cell: 8, frames: 1..6) do |world|
      colors :other, other
      world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
      image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
      dot = sprite :dot, at: [40, 40]
      dot.draw_with :palette_1
      pass = var :pass, 0
      game_loop do
        recolor :palette_1, %i[other palette_0], showing: pass - 2
        pass += 1
      end
    end
  end

  # The backdrop follows a bank's list, as it follows any list: the bank's first colour, which
  # no picture can show.
  def test_a_backdrop_following_a_bank_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1)]
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, advance_tiles, words)
      games = [VBlank::Cartridge::Options.new, LEFT_OUT].map do |options|
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: 4
            slots.numbers :map, at: MAP_AT, count: 2, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
          end
          colors :sky, pack[:palette].bank(1)
          screen :tiled, backdrop: :sky, backdrop_place: 3
          background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 2
          game_loop { wait_vblank }
        end
        b.finalize_program
        [b.program, b.made_data_pack_file]
      end
      (whole, file), (left_out,) = games
      shown = game_player.run(whole, frames: 2).screen

      assert_equal shown(BANKS[1][3]), shown.pixel(100, 100), "the all-in-one build shows the bank's color where no tile draws"
      assert_equal shown.to_a, game_player.hand_file(file).run(left_out, frames: 2).screen.to_a
    end
  end

  # A SHIMMER: four lists, each a bank of another slot of the pack, and a background from the pack
  # that draws one of its own banks with each of them in turn, by a number. The other slot's
  # colours here are the bytes the tiles are kept in, read as colours: sixty-four of them, all
  # unlike the screen's own.
  def test_a_bank_stepped_through_lists_from_the_pack_read_at_start_shows_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3, bank: 1, mirrored: true), ADVANCE_CELL.(1, bank: 1, upside_down: true)]
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, advance_tiles, words)
      games = [VBlank::Cartridge::Options.new, LEFT_OUT].map do |options|
        b = VBlank::Builder.new(options: options)
        b.instance_eval do
          screen :tiled
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: 4
            slots.numbers :map, at: MAP_AT, count: 4, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
            slots.colors :shimmer, at: TILES_AT, count: 64
          end
          shimmers = Array.new(4) { |bank| colors :"shimmer#{bank}", pack[:shimmer].bank(bank) }
          rays = background :rays, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4
          step = var :step, 0
          game_loop do
            rays.draw_with({ palette_1: shimmers }, showing: step)
            wait_vblank
            step.store!(step + 1)
          end
        end
        b.finalize_program
        [b.program, b.made_data_pack_file]
      end
      (whole, file), (left_out,) = games
      seen = (1..7).map do |count|
        shown = game_player.run(whole, frames: count).screen.to_a
        assert_equal shown, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "after #{count} frames the game handed its pack shows what the all-in-one build shows"
        shown
      end

      assert_operator seen.uniq.length, :>=, 5, "each of the four lists, and the bank's own colors after them, is a different picture"
    end
  end

  # A fade of the whole picture needs no colour of a bank while the game is built.
  def test_a_background_read_at_start_fades_as_the_all_in_one_build
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(3), ADVANCE_CELL.(1, bank: 1, mirrored: true)]

    assert_background_plays_alike("faded", :gba, advance_tiles, 4, words, across: 4, cell: 8, frames: [2, 4, 7]) do |_world|
      level = var :level, 0
      game_loop do
        fade :black, level
        wait_vblank
        level.store!(level + 15)
      end
    end
  end

  # The background scrolls as any does: its cells are where the map has them.
  def test_a_background_read_at_start_scrolls_as_the_all_in_one_build
    words = Array.new(64) { |at| ADVANCE_CELL.(1 + (at % 3), bank: (at / 3) % 2, mirrored: at.odd?, upside_down: (at % 5).zero?) }

    assert_background_plays_alike("scrolled", :gba, advance_tiles, 4, words, across: 8, cell: 8, frames: [2, 6]) do |world|
      game_loop do
        wait_vblank
        world.scroll_by 3, 1
      end
    end
  end

  # The game as the block writes it out (as C, JavaScript or Ruby) holds each tile's pixels in its
  # bank's colours when built all-in-one, so the search can find them, and none of them built
  # with its pack left out; nor the tiles' bytes or the banks' colours as the original keeps
  # them. A lowering's test file calls this.
  private def assert_background_written_without_the_originals_bytes(&write)
    cells = [[1, 0], [2, 1], [3, 0]]
    words = cells.map { |tile, bank| ADVANCE_CELL.(tile, bank: bank) }
    drawn = cells.map { |tile, bank| PLACES.fetch(tile).map { |place| place.zero? ? 0xFFFF : BANKS.fetch(bank).fetch(place) } }
    Dir.mktmpdir do |folder|
      from = original(folder, :gba, advance_tiles, words)
      whole, = pack_game_and_file(from, 4, words, across: 3, cell: 8)
      left_out, = pack_game_and_file(from, 4, words, across: 3, cell: 8, options: LEFT_OUT)
      ways_holding_needles([["the background", whole, left_out, drawn]], &write)
      runs = number_runs_in(yield(left_out))
      [advance_tiles.bytes.last(96), BANKS.flatten, BANKS.flatten.pack("v*").bytes].each do |raw|
        assert_empty ways_holding(runs, raw), "the background built with its pack left out holds raw bytes #{raw.first(8)}..."
      end
    end
  end

  # A cell naming a tile past the slot, or a bank past the colours, is refused as the all-in-one
  # build is made. A build that leaves its pack out never reads the map, so the tile draws nothing
  # and the game plays on.
  def test_a_cell_naming_a_tile_past_the_slot_read_at_start_draws_nothing
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(9)]
    drawn = [ADVANCE_CELL.(1), ADVANCE_CELL.(0)]
    Dir.mktmpdir do |folder|
      whole, = pack_game_and_file(original(folder, :gba, advance_tiles, drawn), 4, drawn, across: 2, cell: 8)
      from = original(folder, :gba, advance_tiles, words)
      left_out, = pack_game_and_file(from, 4, words, across: 2, cell: 8, options: LEFT_OUT)
      slots = { video: advance_tiles, map: words.pack("v*"), palette: BANKS.flatten.pack("v*") }
      sha1 = Digest::SHA1.hexdigest(File.binread(File.join(folder, "made_up.bin")))
      file = VBlank::Original::Pack.holding(slots, sha1: sha1, build_version: "1").to_bytes

      assert_equal game_player.run(whole, frames: 2).screen.to_a, game_player.hand_file(file).run(left_out, frames: 2).screen.to_a
    end
  end
end
