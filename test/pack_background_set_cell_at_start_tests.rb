# frozen_string_literal: true

require "tmpdir"
require "all/vblank/dsl/test_pack_background_set_cell"
require "pack_at_start_tests"

# A CELL OF A BACKGROUND FROM THE PACK WRITTEN WITH `set_cell`, ITS PACK LEFT OUT: the games of
# PackBackgroundSetCellGames (test/all/vblank/dsl/test_pack_background_set_cell.rb) built with
# `pack_at_start: true` and handed the pack file the all-in-one build made show what the all-in-one
# build shows, before a cell is written, once it is and once it is blanked again. The answer key
# is the all-in-one build on the interpreter.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackBackgroundSetCellAtStartTests
  include PackBackgroundSetCellGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The game the block builds, all-in-one and with +options+ that leave its pack out, shows one
  # picture after each of +frames+. The block is handed a folder and the build's options, and
  # hands back the game and its pack file. The picture must change between the first and the last
  # of +frames+, so a game whose writes show nothing is not held to be alike.
  private def assert_written_cells_play_alike(what, frames)
    Dir.mktmpdir do |folder|
      whole, file = yield(folder, nil)
      left_out, = yield(folder, LEFT_OUT)
      seen = frames.map do |count|
        shown = game_player.run(whole, frames: count).screen.to_a
        assert_equal shown, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the game handed its pack shows what the all-in-one build shows"
        shown
      end

      refute_equal seen.first, seen.last, "#{what}: the all-in-one build shows the cells written"
    end
  end

  def test_a_genesis_originals_font_cells_written_read_at_start_show_as_the_all_in_one_build
    assert_written_cells_play_alike("the Genesis's", [1, 3, 5]) { |folder, options| genesis_text_game(folder, options: options) }
  end

  # The font's space is a tile that draws nothing, which is known only once the file is read.
  def test_font_cells_blanked_again_read_at_start_show_as_the_all_in_one_build
    assert_written_cells_play_alike("blanked", [3, 4, 6, 8]) do |folder, options|
      genesis_text_game(folder, blank_at: 4, options: options)
    end
  end

  def test_an_advance_originals_turned_cell_written_read_at_start_shows_as_the_all_in_one_build
    assert_written_cells_play_alike("the Advance's", [1, 5]) { |folder, options| advance_turned_cell_game(folder, options: options) }
  end

  def test_a_super_nintendo_originals_big_cell_written_read_at_start_shows_as_the_all_in_one_build
    assert_written_cells_play_alike("the Super Nintendo's", [1, 5]) { |folder, options| snes_big_cell_game(folder, options: options) }
  end

  def test_a_number_in_a_gap_and_one_outside_the_told_cells_read_at_start_show_as_the_all_in_one_build
    first = GENESIS_CELL.(FIRST_FONT_TILE, bank: 1)
    assert_written_cells_play_alike("a gap", [1, 5]) do |folder, options|
      numbered_game(folder, [first, first + 2], [first + 2, first + 1, first - 1, first + 3], options: options)
    end
  end

  def test_told_cells_far_apart_read_at_start_show_as_the_all_in_one_build
    plain = GENESIS_CELL.(FIRST_FONT_TILE)
    turned = GENESIS_CELL.(FIRST_FONT_TILE, mirrored: true)
    other_bank = GENESIS_CELL.(FIRST_FONT_TILE + 1, bank: 1)
    assert_written_cells_play_alike("several runs", [1, 5]) do |folder, options|
      numbered_game(folder, [other_bank, plain, turned], [turned, other_bank, plain + 0x400, plain], options: options)
    end
  end

  def test_a_scenes_background_written_read_at_start_shows_as_the_all_in_one_build
    assert_written_cells_play_alike("a scene's", [1, 6]) { |folder, options| scene_text_game(folder, options: options) }
  end

  # A written cell is drawn in its bank's list, so it is drawn with the list the background is told
  # to draw that bank with, as the map's own cells are: two lists of the game's own in turn, then
  # the bank's own colours.
  def test_a_written_cell_drawn_with_other_lists_read_at_start_shows_as_the_all_in_one_build
    lists = [3, 5].map { |turn| MadeUpOriginalLayouts::PALETTE.rotate(turn).each_with_index.map { |color, at| at.zero? ? :transparent : color } }
    words = MAP_TILES.flatten.map { |tile| ADVANCE_CELL.(tile) }
    base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
    assert_written_cells_play_alike("other lists", [1, 3, 4, 5, 7]) do |folder, options|
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
      pack_game_and_file(from, PLACES.length, words, across: 4, set_cells: base..(base + 1), options: options) do |world|
        lists.each_with_index { |list, at| colors :"other_#{at}", list }
        pass = var :pass, 0
        game_loop do
          world.draw_with({ palette_1: %i[other_0 other_1] }, showing: pass - 2)
          wait_vblank
          pass += 1
          world.set_cell 1, 0, base + 1 if pass == 2
        end
      end
    end
  end

  # `recolor` of the bank a written cell is drawn from reaches the cell, as it reaches the map's
  # cells of that bank and a sprite drawn with it: a list of the game's own, then the other bank,
  # then its own colours again.
  def test_a_written_cell_whose_bank_is_recolored_read_at_start_shows_as_the_all_in_one_build
    other = MadeUpOriginalLayouts::PALETTE.rotate(3).each_with_index.map { |color, at| at.zero? ? :transparent : color }
    words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2, bank: 1), ADVANCE_CELL.(1), ADVANCE_CELL.(2)]
    base = ADVANCE_CELL.(FIRST_FONT_TILE, bank: 1)
    assert_written_cells_play_alike("recoloured", [1, 3, 4, 5, 7]) do |folder, options|
      from = original(folder, :gba, PLACES.map(&LOW_HALF_FIRST).join, words)
      pack_game_and_file(from, PLACES.length, words, across: 4, set_cells: base..(base + 1), options: options) do |world|
        colors :other, other
        world.draw_with({ palette_0: :palette_0, palette_1: :palette_1 })
        image :dot, width: 8, height: 8, places: Array.new(64, 2), colors: :palette_1
        dot = sprite :dot, at: [40, 40]
        dot.draw_with :palette_1
        pass = var :pass, 0
        game_loop do
          recolor :palette_1, %i[other palette_0], showing: pass - 3
          pass += 1
          world.set_cell 2, 0, base + 1 if pass == 2
        end
      end
    end
  end

  # The slot's size and its banks are the game's own words, so a told cell past either is refused
  # as the game is built, whichever way it is built.
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

  # `set_tile` names a tile of the background's own, and which tiles the map draws is in the file.
  # Only the told cells' tiles are known as the game is built, and `set_cell` is what writes those.
  def test_set_tile_by_a_number_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        advance_game(folder, set_cells: [ADVANCE_CELL.(3)], options: LEFT_OUT) do |world|
          which = var :which, 0
          game_loop do
            wait_vblank
            world.set_tile 0, 0, which
          end
        end
      end

      assert_includes error.message, "set_tile"
      assert_includes error.message, "set_cell"
    end
  end
end
