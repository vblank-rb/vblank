# frozen_string_literal: true

require "test_helper"
require "stringio"

# A cell given a tile the game works out as it plays costs what a cell given a tile written in the
# program does. The cells' words are kept in a table in the cartridge and the number picks one, so the
# cost does not grow with the tiles the background has: a letter written from a number costs as it
# does in a game with a few tiles. The profiler reads the part of the frame the console was awake
# against the same game writing constants.
class TestGBASetCellCost < Minitest::Test
  include VBlank::Testing::Pictures

  # A frame's processor cycles: 228 lines of 1232.
  FRAME_CYCLES = 228 * 1232
  WRITES = 24

  # A game writing +WRITES+ cells a pass from a tileset of +count+ tiles: each the tile of a number worked
  # out from the pass where +worked_out+, else a tile named in the program.
  def self.game(count, worked_out:)
    VBlank.game("CELLS #{count}", consoles: %i[gba]) do
      screen :tiled
      images = (0...count).to_h do |n|
        name = :"tile_#{n}"
        image(name, width: 8, height: 8, data: Array.new(64) { |at| ((at + n) % 3).zero? ? :red : :blue })
        [n, name]
      end
      tiles :set, images
      field = background :field, tiles: :set, map: Array.new(28) { Array.new(32) { 0 } }
      step = var :step, 0
      game_loop do
        step += 1
        WRITES.times do |at|
          if worked_out
            field.set_tile at, 3, (step + at) & (count - 1)
          else
            field.set_tile at, 3, (at * 5) & (count - 1)
          end
        end
      end
    end
  end

  private def game_cycles(game)
    rom = game.build_rom(console: :gba, out: StringIO.new, err: StringIO.new, profile: false)
    (1 - rom.profile(out: StringIO.new, settle: 10, frames: 30).idle_share) * FRAME_CYCLES
  end

  # A write from a number is the number read, held to the table, the table read and one store: about a
  # dozen instructions, and under 70 cycles with the number worked out from the pass. Searching the
  # tiles for the number took a test for each halving of them and a store of its own at the end.
  def test_a_worked_out_cell_costs_under_70_cycles_more_than_one_written_in_the_program
    worked = game_cycles(self.class.game(32, worked_out: true))
    written = game_cycles(self.class.game(32, worked_out: false))

    assert_operator (worked - written) / WRITES, :<, 70, "cycles a write: #{worked} worked out against #{written} written"
  end

  def test_the_cost_does_not_grow_with_the_tiles
    few = game_cycles(self.class.game(4, worked_out: true))
    many = game_cycles(self.class.game(64, worked_out: true))

    assert_operator (many - few) / WRITES, :<, 0.5, "cycles a write: #{many} with 64 tiles against #{few} with 4"
  end

  # What is on the screen is the interpreter's: numbers past either end of the table leave the cell as
  # it was, and so does a place off the map.
  def test_cells_picked_by_numbers_past_the_table_show_as_the_interpreter_shows_them
    game = VBlank.game("PICKED", consoles: %i[gba]) do
      screen :tiled
      images = (0...6).to_h do |n|
        image(:"tile_#{n}", width: 8, height: 8, data: Array.new(64) { |at| ((at / 8) + n).even? ? :red : %i[blue green white yellow cyan magenta][n] })
        [n, :"tile_#{n}"]
      end
      tiles :set, images
      field = background :field, tiles: :set, map: Array.new(20) { Array.new(30) { 0 } }
      step = var :step, 0
      game_loop do
        step += 1
        10.times { |at| field.set_tile at * 3, (at % 4) + 2, step - 3 + at }
        field.set_tile 40, 3, step
      end
    end

    assert_backends_agree(game.program(console: :gba), frames: 6)
  end

  # A map too big to keep whole, brought into view a strip at a time, and a background that holds its
  # changes for the gap: each writes the tests the number stands for, and shows what the interpreter does.
  def test_a_streamed_map_and_a_held_background_take_a_worked_out_tile_as_the_interpreter_does
    [{ size: 96, held: false }, { size: 32, held: true }].each do |shape|
      size = shape[:size]
      held = shape[:held]
      game = VBlank.game("PICKED", consoles: %i[gba]) do
        screen :tiled
        images = (0...4).to_h do |n|
          image(:"tile_#{n}", width: 8, height: 8, data: Array.new(64) { |at| ((at / 8) + n).even? ? :red : %i[blue green white yellow][n] })
          [n, :"tile_#{n}"]
        end
        tiles :set, images
        field = background :field, tiles: :set, map: Array.new(size) { Array.new(size) { 0 } }, held: held
        step = var :step, 0
        game_loop do
          step += 1
          6.times { |at| field.set_tile (at * 3) + 1, 4, step + at - 2 }
        end
      end

      assert_backends_agree(game.program(console: :gba), frames: 6)
    end
  end
end
