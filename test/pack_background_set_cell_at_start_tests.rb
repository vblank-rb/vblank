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
end
