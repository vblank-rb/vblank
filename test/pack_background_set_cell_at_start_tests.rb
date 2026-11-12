# frozen_string_literal: true

require "tmpdir"
require "all/vblank/dsl/test_pack_background_set_cell"
require "pack_at_start_tests"

# A CELL OF A BACKGROUND FROM THE PACK WRITTEN WITH `set_cell`, ITS PACK LEFT OUT: the slot's size
# and its banks are the game's own words, so a told cell past either is refused as the game is
# built, whichever way it is built. That the games of PackBackgroundSetCellGames
# (test/all/vblank/dsl/test_pack_background_set_cell.rb) play as their all-in-one builds is the
# registry's (PackGames::WrittenCells, test/pack_games.rb).
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackBackgroundSetCellAtStartTests
  include PackBackgroundSetCellGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  def test_a_told_cell_drawing_a_tile_past_the_slot_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { advance_game(folder, set_cells: [ADVANCE_CELL.(40)], options: LEFT_OUT) }

      assert_includes error.message, "tile 40"
    end
  end

  def test_a_told_cell_drawn_from_a_bank_past_the_colors_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { advance_game(folder, set_cells: [ADVANCE_CELL.(3, bank: 5)], options: LEFT_OUT) }

      assert_includes error.message, "bank 5"
    end
  end

  # The same on a map of map cells, a told record naming a tile past the slot.
  def test_a_told_map_cell_drawing_a_tile_past_the_slot_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      told = [VBlank::Original::MapCell::Cell.new(tile: 400, bank: 1)]
      error = assert_raises(ArgumentError) { map_cells_game_and_file(folder, :gbc, set_cells: told, options: LEFT_OUT) }

      assert_includes error.message, "tile 400"
    end
  end

  # With the pack left out the screen is read as the game starts, and the text written on it in
  # the record's terms shows as the Advance original's all-in-one. The Color original's games are
  # played the same way by the registry (PackGames::WrittenCells).
  def test_text_written_on_map_cells_with_the_pack_left_out_shows_as_the_advances
    Dir.mktmpdir do |folder|
      expected = game_player.run(advance_text_game(folder).first, frames: 5).screen.to_a
      program, file = map_cells_text_game(folder, :pc, records: true)
      left_out, = map_cells_text_game(folder, :pc, records: true, options: LEFT_OUT)

      assert_equal expected, game_player.run(program, frames: 5).screen.to_a
      assert_equal expected, game_player.hand_file(file).run(left_out, frames: 5).screen.to_a
    end
  end
end
