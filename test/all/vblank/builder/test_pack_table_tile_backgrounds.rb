# frozen_string_literal: true

require "test_helper"
require "pack_table_tile_background_games"

# WHAT A GAME IS TOLD when a map of map cells over tiles of 256 colours names a bank of colours
# (Builder::PackBackgrounds), and what such tiles under cells of 16x16 are made of. A tile of 256
# colours picks from the whole table, so a cell has no bank to pick. What such a background shows
# is test/console/gba/vblank/builder/test_pack_table_tile_backgrounds_on_the_advance.rb's.
class TestPackTableTileBackgrounds < Minitest::Test
  include PackTableTileBackgroundGames

  def test_a_map_cell_naming_a_bank_over_tiles_of_256_colors_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        table_tile_pack_game_and_file(table_tile_original(folder), map: :banked_map_cells) { |_layer| game_loop { wait_vblank } }
      end

      assert_includes error.message, "bank 1"
      assert_includes error.message, "256 colors"
    end
  end

  # A Super Nintendo build makes a cell of 16x16 one picture drawn from a bank's list, and tiles
  # of 256 colours have no list, so such a background keeps tiles of 8x8. No Super Nintendo
  # cartridge draws a background of 256 colours, so it is played on the interpreter by name: each
  # 16x16 cell shows its four tiles of the made-up original, the second cell mirrored whole.
  def test_cells_of_16x16_over_tiles_of_256_colors_on_the_super_nintendo_are_four_tiles_each
    Dir.mktmpdir do |folder|
      words = [1 | (2 << 10), 3 | (1 << 14)] # bank 2, which is not read; and mirrored
      from = super_nintendo_original(folder, words)
      b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
      b.instance_eval do
        screen :tiled
        pack = data_pack from: from, version: "1" do |slots|
          slots.tiles :pictures, at: TILES_AT, count: 40, colors: 256
          slots.numbers :cells, at: MAP_AT, count: words.length, width: :half, signed: false
          slots.colors :table, at: COLORS_AT, count: TABLE.length
        end
        background :layer, tiles: pack[:pictures], map: pack[:cells], colors: pack[:table], across: 2, cell: 16
        game_loop { wait_vblank }
      end
      b.finalize_program
      screen = Reference.new.run(b.program, frames: 2).screen

      # The cell at tile t is tiles t, t + 1, t + 16 and t + 17; mirrored, its right half is tile t's.
      [[1, 0, 0, false], [2, 8, 0, false], [17, 0, 8, false], [4, 16, 0, true], [3, 24, 0, true]].each do |tile, left, top, mirrored|
        expected = TILES.fetch(tile).each_slice(8).map { |row| mirrored ? row.reverse : row }.flatten
        drawn = Array.new(64) { |at| screen.pixel(left + (at % 8), top + (at / 8)) }
        expected.zip(drawn).each_with_index do |(place, color), at|
          next if place.zero?

          assert_equal TABLE.fetch(place), color, "tile #{tile} at (#{left}, #{top}), pixel #{at}"
        end
      end
    end
  end

  # A made-up Super Nintendo original of the same tiles and table, its map +words+.
  private def super_nintendo_original(folder, words)
    copy = "\0".b * COPY_SIZE
    copy[COLORS_AT, TABLE.length * 2] = TABLE.pack("v*")
    copy[MAP_AT, words.length * 2] = words.pack("v*")
    copy[TILES_AT, TILES.length * 64] = TILES.flatten.pack("C*")
    path = File.join(folder, "made_up_snes_table_tiles.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end
end
