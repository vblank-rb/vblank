# frozen_string_literal: true

require "test_helper"
require "made_up_original_layouts"
require "pack_background_tests"

# A BACKGROUND FROM THE DATA PACK WHOSE CELLS ARE 16x16, BUILT FOR THE SUPER NINTENDO, which draws
# such a cell as one tile (Builder::PackBackgrounds#big_pack_cells?). The answer key is the made-up
# original: a cell at tile t is tiles t, t + 1, t + 16 and t + 17 of its video memory, drawn from
# its bank and turned whole.
class TestPackBigCellsOnTheSuperNintendo < Minitest::Test
  include PackBackgroundGames

  BUILT_FOR_THE_SNES = VBlank::Cartridge::Options.new(console: :snes)

  # Twenty tiles of video memory: the picture's cell at tile 0 and a letter's at tile 2, each of
  # four tiles that differ, and every other tile blank.
  VIDEO = Array.new(20) { PLACES[0] }.tap do |video|
    [[0, 1], [1, 2], [16, 3], [17, 1], [2, 2], [3, 3], [18, 1], [19, 2]].each { |tile, places| video[tile] = PLACES[places] }
  end.freeze

  # The cell at tile +first+ as drawn, 16 rows of 16 places, a tile of it that is a key of
  # +shown+ drawn as the tile it gives.
  private def big_places(first, shown = {})
    Array.new(16) do |y|
      Array.new(16) do |x|
        tile = first + ((y / 8) * 16) + (x / 8)
        VIDEO.fetch(shown.fetch(tile, tile)).fetch(((y % 8) * 8) + (x % 8))
      end
    end
  end

  # Every pixel the cell at tile +first+ draws, at (+at_x+, 0), from +bank+, turned as +turn+ says,
  # with the tiles of +shown+ (#big_places) taking turns.
  private def assert_big_cell(screen, first, at_x, bank, mirrored: false, upside_down: false, shown: {})
    places = big_places(first, shown)
    16.times do |y|
      16.times do |x|
        place = places.fetch(upside_down ? 15 - y : y).fetch(mirrored ? 15 - x : x)
        next if place.zero?

        assert_equal BANKS.fetch(bank).fetch(place), screen.pixel(at_x + x, y), "the pixel (#{x}, #{y}) of the cell at #{at_x}"
      end
    end
  end

  private def snes_tiles = VIDEO.map(&MadeUpOriginalLayouts::FOUR_PLANES).join

  def test_a_cell_of_16x16_is_drawn_whole_from_its_bank_and_turned_whole
    Dir.mktmpdir do |folder|
      words = [SNES_CELL.(0), SNES_CELL.(0, bank: 1, mirrored: true), SNES_CELL.(2, upside_down: true)]
      program = pack_game(original(folder, :snes, snes_tiles, words), VIDEO.length, words, across: 3, cell: 16,
                                                                                            options: BUILT_FOR_THE_SNES)
      screen = game_player.run(program, frames: 3).screen

      assert_big_cell(screen, 0, 0, 0)
      assert_big_cell(screen, 0, 16, 1, mirrored: true)
      assert_big_cell(screen, 2, 32, 0, upside_down: true)
    end
  end

  # On its second pass the game writes the letter mirrored at (0, 0), written in the game, and the
  # letter in the other bank, kept in a variable, at (1, 0).
  def test_a_told_cell_of_16x16_is_written_whole
    Dir.mktmpdir do |folder|
      words = [SNES_CELL.(0), SNES_CELL.(0)]
      letter = SNES_CELL.(2, bank: 1)
      turned = SNES_CELL.(2, mirrored: true)
      from = original(folder, :snes, snes_tiles, words)
      b = VBlank::Builder.new(options: BUILT_FOR_THE_SNES)
      b.instance_eval do
        screen :tiled
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :video, at: TILES_AT, count: VIDEO.length, colors: 16
          slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
          slots.colors :palette, at: COLORS_AT, count: 32
        end
        world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 2, cell: 16,
                                   set_cells: [letter, turned]
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
      b.finalize_program
      screen = game_player.run(b.program, frames: 5).screen

      assert_big_cell(screen, 2, 0, 0, mirrored: true)
      assert_big_cell(screen, 2, 16, 1)
    end
  end

  # Tile 17, the bottom right quarter of the cell at tile 0, takes turns through tiles 19 and 3,
  # neither of which it starts as. The map shows the cell at (0, 0); on its second pass the game
  # writes it at (1, 0) in the other bank, mirrored and upside down, from a number kept in a variable; from its
  # sixth the group shows its second picture. Each cell is one 16x16 tile of a run, turned whole.
  def test_a_cell_of_16x16_with_a_quarter_taking_turns_shows_each_picture_turned_whole
    Dir.mktmpdir do |folder|
      words = [SNES_CELL.(0), SNES_CELL.(0)]
      written = SNES_CELL.(0, bank: 1, mirrored: true, upside_down: true)
      from = original(folder, :snes, snes_tiles, words)
      b = VBlank::Builder.new(options: BUILT_FOR_THE_SNES)
      b.instance_eval do
        screen :tiled
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :video, at: TILES_AT, count: VIDEO.length, colors: 16
          slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
          slots.colors :palette, at: COLORS_AT, count: 32
        end
        lamp = tile_pictures :lamp, tiles: { pack[:video].tile(17) => [pack[:video].tile(19), pack[:video].tile(3)] }
        world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 2, cell: 16,
                                   set_cells: [written]
        which = var :which, written
        pass = var :pass, 0
        game_loop do
          wait_vblank
          pass += 1
          world.set_cell pass - 1, 0, which if pass == 2
          lamp.show 1 if pass == 6
        end
      end
      b.finalize_program
      first = game_player.run(b.program, frames: 4).screen

      assert_big_cell(first, 0, 0, 0, shown: { 17 => 19 })
      assert_big_cell(first, 0, 16, 1, mirrored: true, upside_down: true, shown: { 17 => 19 })

      later = game_player.run(b.program, frames: 10).screen

      assert_big_cell(later, 0, 0, 0, shown: { 17 => 3 })
      assert_big_cell(later, 0, 16, 1, mirrored: true, upside_down: true, shown: { 17 => 3 })
    end
  end
end
