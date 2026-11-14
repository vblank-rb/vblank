# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "all/vblank/dsl/test_pack_background_set_cell"

# A CELL WRITTEN BY A NUMBER THE GAME WORKS OUT, on a background told its cells by a slot of the
# pack, on the Color. A port's screen changes to a few hundred told cells, and the frames that
# write them already run close, so what one `set_cell` costs must not grow with how many cells
# the background was told: the Color reads the cell from a table by the number, as the original
# does, rather than testing the number against the told cells.
class TestGBCToldCellsCost < Minitest::Test
  include PackBackgroundSetCellGames

  WRITES_A_PASS = 16

  # A game whose background is told +changes+ cells by a slot, writing WRITES_A_PASS of them a
  # pass, each by a place it works out.
  private def busy_game(folder, changes)
    from = map_cells_original(folder, :gbc)
    cells = MAP_TILES.flatten.length
    VBlank.game("TOLD #{changes}", consoles: %i[gbc]) do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: MAP_CELLS_VIDEO.length
        slots.colors :palette, at: COLORS_AT, count: MAP_CELLS_PALETTE.length
        slots.map_cells :map, count: cells
        slots.map_cells :changes, count: changes
        slots.fill_from_copy do |copy, filled|
          repeat(cells) { |at| filled[:map].write_cell(at, tile: copy.byte(MAP_CELLS_TILE_MAP_AT + at)) }
          changes.times { |at| filled[:changes].write_cell(at, tile: MAP_CELLS_BANK_TILES + (at % 3), bank: 1) }
        end
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 4, set_cells: pack[:changes]
      place = var :place, 0
      game_loop do
        WRITES_A_PASS.times { |n| world.set_cell n % 4, (n / 4) % 2, place }
        place += 1
        place.store!(0) if place >= 3
      end
    end
  end

  private def idle_share(game)
    game.build_rom(console: :gbc, out: StringIO.new, err: StringIO.new, profile: false).profile(out: StringIO.new, frames: 30).idle_share
  end

  def test_a_worked_out_cell_costs_the_same_however_many_cells_are_told
    Dir.mktmpdir do |folder|
      few = idle_share(busy_game(folder, 4))
      many = idle_share(busy_game(folder, 200))

      assert_in_delta few, many, 0.005, "writing a cell of 200 told cells costs #{(few - many).round(4)} of a frame more than of 4"
    end
  end
end
