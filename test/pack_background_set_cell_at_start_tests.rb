# frozen_string_literal: true

require "tmpdir"
require "all/vblank/dsl/test_pack_background_set_cell"
require "pack_at_start_tests"

# A cell of a background from the pack written with `set_cell`, its pack left out: the slot's size
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
  # Frames after which a game blanking its text on pass 4 shows the text, and then the blank.
  WRITTEN_AND_BLANKED_FRAMES = [3, 8].freeze

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

  # What a slot of told cells holds is the player's file's, so nothing in it stops the game: a told
  # cell naming a tile past the slot of tiles draws nothing, as the font's space does, and the
  # other told cells draw as they would.
  def test_a_told_slot_cell_of_the_file_naming_a_tile_past_the_slot_draws_nothing
    Dir.mktmpdir do |folder|
      written = game_player.run(slot_told_text_game(folder, :gbc).first, frames: 5).screen
      blanked = game_player.run(slot_told_text_game(folder, :gbc, blank_at: 4).first, frames: 8).screen
      _, file = slot_told_text_game(folder, :gbc)
      left_out, = slot_told_text_game(folder, :gbc, options: LEFT_OUT)
      pack = VBlank::Original::Pack.from_bytes(file)
      changes = pack.slots.fetch(:changes).dup
      changes[0, VBlank::Original::MapCell::BYTES] = [VBlank::Original::MapCell.number(tile: 9999, bank: 1)].pack("V")
      wild = game_player.hand_file(pack.with(slots: pack.slots.merge(changes: changes)).to_bytes).run(left_out, frames: 5).screen
      cell = ->(screen, col, row) { (0...64).map { |at| screen.pixel((col * 8) + (at % 8), (row * 8) + (at / 8)) } }

      assert_equal cell.(blanked, 1, 1), cell.(wild, 1, 1), "the told cell naming a tile past the slot draws something"
      assert_equal cell.(written, 2, 1), cell.(wild, 2, 1), "the other told cell does not draw as written"
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

  # A block of cells put back with the pack left out (`restore_cells`): the map is the file's, read
  # as the game starts, so the cells go back to what the all-in-one build puts back, the map's
  # empty cell (2, 1) emptied again. A block of told cells covers part of the map on pass 2, part
  # of it, and some of the map past its edge, is put back on pass 4, and the rest on pass 6.
  def test_cells_put_back_with_the_pack_left_out_show_as_the_all_in_one_builds
    Dir.mktmpdir do |folder|
      game = lambda do |**settings|
        map_cells_game_and_file(folder, :gbc, set_cells: ->(pack) { pack[:changes] }, changes: 3, **settings) do |world|
          t = var :t, 0
          game_loop do
            t += 1
            world.fill_cells 0, 0, 4, 2, 1 if t == 2
            world.restore_cells 1, -1, 2, 5 if t == 4
            world.restore_cells 0, 0, 9, 9 if t == 6
          end
        end
      end
      program, file = game.()
      left_out, = game.(options: LEFT_OUT)
      all_in_one = pictures_of_frames(program, [3, 5, 7])

      refute_equal all_in_one[0], all_in_one[2], "the block showed, and was put back"
      assert_equal all_in_one, pictures_of_frames(left_out, [3, 5, 7], file: file)
    end
  end

  # The picture after each of +frames+, played by this run's player, handed +file+ where given.
  private def pictures_of_frames(program, frames, file: nil)
    frames.map do |count|
      player = file ? game_player.hand_file(file) : game_player
      player.run(program, frames: count).screen.to_a
    end
  end

  # Written `now: true` with the pack left out, by number and by place, the cells show what the
  # all-in-one build shows written without it. Played as a console that writes its video memory
  # only between frames, the game is refused as its all-in-one build is (TestPackBackgroundSetCell).
  def test_cells_written_now_with_the_pack_left_out_show_as_written_for_the_gap
    shows_now = VBlank::Console.described(VBlank::Testing.console).changes_cells_while_drawing
    Dir.mktmpdir do |folder|
      { "by number" => ->(**settings) { map_cells_text_game(folder, :gbc, blank_at: 4, **settings) },
        "by place" => ->(**settings) { slot_told_text_game(folder, :gbc, blank_at: 4, **settings) } }.each do |how, game|
        program, file = game.()
        left_out, = game.(now: true, options: LEFT_OUT)
        unless shows_now
          error = assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.hand_file(file).run(left_out, frames: 3) }
          assert_match(/between frames/, error.message, how)
          next
        end

        WRITTEN_AND_BLANKED_FRAMES.each do |frames|
          assert_equal game_player.run(program, frames: frames).screen.to_a,
                       game_player.hand_file(file).run(left_out, frames: frames).screen.to_a, "#{how}, after #{frames} frames"
        end
      end
    end
  end
end
