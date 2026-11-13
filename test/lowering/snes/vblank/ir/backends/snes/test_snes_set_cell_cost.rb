# frozen_string_literal: true

require "test_helper"
require "stringio"
require "json"
require "made_up_original_layouts"
require "pack_background_tests"

# A CELL WRITTEN FROM A NUMBER WORKED OUT AS THE GAME PLAYS COSTS WHAT A CELL WRITTEN FROM A NUMBER
# IN THE PROGRAM DOES. A Super Nintendo game writes its map's words straight into its copy of the
# map: a blast spreading over an arena is a dozen words a frame, each read from a table of the
# game's. Here the game's arena is a background from the data pack of 16x16 cells, told 80 cells
# set_cell may write, and every pass writes a dozen of them, the word worked out from the pass.
class TestSNESSetCellCost < Minitest::Test
  include PackBackgroundGames

  ACROSS = 16
  DOWN = 14
  TOLD = 80
  WRITES = 12
  # The told cells are at tiles 0, 2, 4 ... of video memory: a cell at tile t is t, t + 1, t + 16
  # and t + 17. Tile 17 takes turns in the games that say so: the bottom right quarter of cell 0
  # and the top right of cell 8, which the map shows and the game writes.
  TILE_COUNT = (2 * (TOLD - 1)) + 19
  MOVING_TILE = 17
  TILE_PLACES = Array.new(TILE_COUNT) { |tile| Array.new(64) { |at| 1 + (((at * 7) + (tile * 13) + (at * tile)) % 15) } }
  MAP_AT = 0x100
  BIG_TILES_AT = 0x1000
  FRAMES = 40

  # How much more of a frame each tile of a worked-out cell may take than the same tile written in
  # the program: the number held to the table and a read of it, about half of one of the frame's
  # 262 lines. Searching the told numbers for the tile took several times that.
  MOST_EXTRA_SHARE_A_TILE = 0.002

  def test_a_pass_writing_a_dozen_worked_out_cells_fits_in_a_frame
    [false, true].each do |moving|
      out = StringIO.new
      Dir.mktmpdir do |folder|
        rom_of(arena_game(folder, worked_out: true, moving: moving)).profile(format: :json, out: out, frames: FRAMES, settle: 10)
      end

      assert_equal ["1"], JSON.parse(out.string).fetch("passes_by_frames").keys, "moving: #{moving}"
    end
  end

  # Cells of 16x16 tiles: one write a cell.
  def test_a_worked_out_cell_costs_about_what_a_cell_written_in_the_program_does
    assert_worked_out_costs_about_written(moving: false)
  end

  # A cell with a quarter that takes turns is still one tile of 16x16, as the console's own game
  # keeps it: one write a cell, as in a game whose slot has no such tile.
  def test_a_worked_out_cell_with_a_tile_taking_turns_costs_about_one_cell_written_in_the_program
    assert_worked_out_costs_about_written(moving: true)
  end

  def test_worked_out_cells_show_as_the_interpreter_says
    [false, true].each do |moving|
      Dir.mktmpdir do |folder|
        game = arena_game(folder, worked_out: true, moving: moving, showing: moving)
        VBlank::IR::Backends::SNES::CheckedRun.new.run(game.program(console: :snes), frames: 8)
      end
    end
    pass
  end

  # Against cells written in the program on an arena with no tile taking turns: what a 16x16 cell
  # written by name costs.
  private def assert_worked_out_costs_about_written(moving:)
    Dir.mktmpdir do |folder|
      worked_out = rom_of(arena_game(folder, worked_out: true, moving: moving)).profile(out: StringIO.new, frames: FRAMES, settle: 10)
      written = rom_of(arena_game(folder, worked_out: false)).profile(out: StringIO.new, frames: FRAMES, settle: 10)

      assert_operator (written.idle_share - worked_out.idle_share) / WRITES, :<, MOST_EXTRA_SHARE_A_TILE,
                      "idle: #{worked_out.idle_share} worked out against #{written.idle_share} written in the program"
    end
  end

  private def rom_of(game) = game.build_rom(console: :snes, out: StringIO.new, err: StringIO.new, profile: false)

  private def arena_original(folder)
    tiles = TILE_PLACES.map(&MadeUpOriginalLayouts::FOUR_PLANES).join
    copy = "\0".b * (BIG_TILES_AT + tiles.bytesize)
    copy[COLORS_AT, 32] = BANKS.first.pack("v*")
    copy[MAP_AT, ACROSS * DOWN * 2] = Array.new(ACROSS * DOWN) { |at| SNES_CELL.(2 * (at % TOLD)) }.pack("v*")
    copy[BIG_TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The arena, and each pass WRITES cells written along its top rows: with +worked_out+ each word
  # worked out from the pass, otherwise each the told word written in the program. With +moving+ a
  # tile of the slot takes turns through pictures, and with +showing+ as well the group shows the
  # next picture every other pass.
  private def arena_game(folder, worked_out:, moving: false, showing: false)
    from = arena_original(folder)
    told = Array.new(TOLD) { |cell| SNES_CELL.(2 * cell) }
    VBlank.game("ARENA", consoles: %i[snes]) do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: BIG_TILES_AT, count: TILE_COUNT, colors: 16
        slots.numbers :map, at: MAP_AT, count: ACROSS * DOWN, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 16
      end
      lamp = (tile_pictures :lamp, tiles: { pack[:video].tile(MOVING_TILE) => [pack[:video].tile(0), pack[:video].tile(1)] } if moving)
      arena = background :arena, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS, cell: 16,
                                 set_cells: told
      pass = var :pass, 0
      word = var :word, 0
      game_loop do
        pass += 1
        lamp.show((pass / 2) % 2) if showing
        WRITES.times do |at|
          # Both games work the word out, so the two differ only in how the cell is written.
          word = told.first + (((pass + (at * 7)) % TOLD) * 2)
          if worked_out
            arena.set_cell at % ACROSS, at / ACROSS, word
          else
            arena.set_cell at % ACROSS, at / ACROSS, told[(at * 7) % TOLD]
          end
        end
      end
    end
  end
end
