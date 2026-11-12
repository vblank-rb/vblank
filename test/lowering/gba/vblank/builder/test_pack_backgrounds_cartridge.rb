# frozen_string_literal: true

require "test_helper"
require "differential"
require "pack_background_tests"
require "pack_turning_background_games"

# A BACKGROUND FROM THE DATA PACK ON THE ADVANCE'S CARTRIDGE, read in the emulator. What such a
# background shows on every run is in test/all/vblank/builder/test_pack_backgrounds.rb.
class TestPackBackgroundsCartridge < Minitest::Test
  include PackBackgroundGames
  include PackTurningBackgroundGames
  include Differential

  private def see_through_first(colors) = colors.each_with_index.map { |color, at| at.zero? ? :transparent : color }

  # A map with a cell in each of two banks, both told `recolor`, each on a pass of its own, and a
  # sprite drawn with each bank.
  private def two_banks_recolored(folder)
    first = see_through_first(OTHER)
    second = see_through_first(LATER)
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1)]
    pack_game(original(folder, :gba, advance_tiles, words), 4, words, across: 2, cell: 8) do |world|
      colors :first, first
      colors :second, second
      world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
      %i[palette_0 palette_1].each_with_index do |bank, at|
        image :"dot_#{at}", width: 8, height: 8, places: Array.new(64, 2), colors: bank
        sprite(:"dot_#{at}", at: [40 + (at * 20), 40]).draw_with bank
      end
      pass = var :pass, 0
      game_loop do
        pass += 1
        recolor :palette_0, :first if pass >= 3
        recolor :palette_1, :second if pass >= 5
      end
    end
  end

  def test_a_background_follows_two_banks_the_game_recolors
    Dir.mktmpdir do |folder|
      assert_backends_agree(two_banks_recolored(folder), frames: 1..7)
    end
  end

  # A MAP OF CELLS OF VBLANK'S OWN, written by the unpacking from a Color original's two maps, on
  # the Advance's cartridge, every bank walked up from black by its name.
  def test_a_map_of_cells_walked_by_its_banks_names_shows_on_the_cartridge_as_on_the_interpreter
    Dir.mktmpdir do |folder|
      program, = color_cells_game_and_file(color_original(folder), walked: true)

      assert_backends_agree(program, frames: [2, 4, COLOR_WALK_STEPS + 3])
    end
  end

  # A LAYER THAT TURNS, FROM THE PACK (PackTurningBackgroundGames): a map of bytes over tiles of a
  # byte a pixel. The cartridge shows what the interpreter shows as the game eases its size and
  # turns it about its map's middle, set down at a point of the screen.
  def test_a_turning_background_from_the_pack_shows_on_the_cartridge_as_on_the_interpreter
    Dir.mktmpdir do |folder|
      program = turning_pack_game(turning_original(folder)) do |layer|
        layer.turns_around(*PIVOT, map_point: MIDDLE).scale(4.0)
        spin = var :spin, 0
        game_loop do
          layer.scale.approach! 1.0, 0.25
          spin += 7
          layer.rotate spin
        end
      end

      assert_backends_agree(program, frames: [2, 4, 7, 11, 16])
    end
  end

  # The console's own pixels, held to the made-up data: at twice its size about its middle, the
  # map's pixel sixteen right of the middle is thirty-two right of the pivot.
  def test_the_console_shows_a_turning_background_from_the_pack_in_its_tables_colors
    Dir.mktmpdir do |folder|
      program = turning_pack_game(turning_original(folder)) do |layer|
        layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
        game_loop { wait_vblank }
      end
      v = assert_emulator_loads_rom(assemble_rom(program, name: "PACKTURN"), frames: 4)

      assert_equal turning_map_color(*MIDDLE), v.pixel_gba(*PIVOT)
      assert_equal turning_map_color(MIDDLE[0] + 16, MIDDLE[1] + 3), v.pixel_gba(PIVOT[0] + 32, PIVOT[1] + 6)
    end
  end

  # The console's own pixels, held to the made-up colours: bank 1's cell holds :second by now.
  def test_the_console_shows_a_cell_in_what_its_bank_holds
    Dir.mktmpdir do |folder|
      v = assert_emulator_loads_rom(assemble_rom(two_banks_recolored(folder), name: "BANKS"), frames: 9)
      # Tile 2's first row is places 1, 1, 1, 2, 2, 2, 3, 3.
      shown = [8, 11, 14].map { |x| v.pixel_gba(x, 0) }

      assert_equal LATER.values_at(1, 2, 3), shown
    end
  end
end
