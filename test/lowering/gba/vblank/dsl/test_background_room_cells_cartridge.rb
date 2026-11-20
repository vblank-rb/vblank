# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/dsl/test_background_room_cells"

# A CELL OF A ROOM CHANGED WHILE THE GAME RUNS, on the Advance's cartridge, read in the emulator.
# What it shows on every run is in test/all/vblank/dsl/test_background_room_cells.rb. A map the
# cartridge brings into view a strip at a time keeps the changed cell as the view moves, and a
# cell of a second area of its own tiles is that area's picture.
class TestBackgroundRoomCellsCartridge < Minitest::Test
  include RoomCellGames
  include Differential

  # The frames each moment of the walk is read at.
  MOMENT_FRAMES = MOMENTS.map(&:first).freeze

  def test_a_room_of_its_own_size_keeps_its_changed_cell_through_scrolling
    assert_backends_agree(RoomCellGames.baked_rooms_game, frames: MOMENT_FRAMES)
  end

  def test_rooms_of_one_size_take_the_tile_of_the_area_showing
    assert_backends_agree(RoomCellGames.baked_rooms_game(same_size: true), frames: MOMENT_FRAMES)
  end

  def test_a_map_too_big_to_hold_whole_keeps_its_changed_cell_through_scrolling
    assert_backends_agree(RoomCellGames.big_room_game, frames: [OPEN_IN_HALL, SCROLL_AWAY, SCROLL_BACK].map { |pass| pass + SETTLED })
  end

  # The loop's count is kept in two registers; the routine changing a cell leaves them as they were.
  def test_cells_of_a_big_map_changed_in_a_loop_are_each_changed
    assert_backends_agree(RoomCellGames.big_room_looped_game, frames: 4)
  end

  # The copy of a changed map holds the processor while it runs, so a map whose copy would take
  # longer than the sound mixer can wait is refused, naming the most cells the build keeps.
  def test_a_changed_map_too_big_to_copy_in_time_is_refused
    program = VBlank::Builder.new.tap do |b|
      b.instance_eval do
        screen :tiled
        RoomCellGames.declare_room_tiles(self)
        ground = background :ground, tiles: :house_tiles, map: ["." * 120] * 100
        game_loop { ground.set_tile 1, 1, "o" }
      end
      b.finalize_program
    end.program

    error = assert_raises(VBlank::IR::Backends::GBA::LoweringError) { assemble_rom(program) }
    assert_match(/at most \d+ cells/, error.message)
  end

  # A game that changes no cell of its big map keeps no copy of it: the strips come from the
  # cartridge, and the build holds no routine changing a cell.
  def test_a_big_map_the_game_never_changes_keeps_no_copy
    unchanged = VBlank::Builder.new.tap do |b|
      b.instance_eval do
        screen :tiled
        RoomCellGames.declare_room_tiles(self)
        background :ground, tiles: :house_tiles, map: ["." * 80] * 20
        game_loop { wait_vblank }
      end
      b.finalize_program
    end.program
    routines = ->(program) { assemble_rom(program).built.routines.keys.map { |name| VBlank::Messages::MadeNames.words_for_made_name(name) } }

    refute_includes routines.(unchanged), "changing a cell of the map of background :ground"
    assert_includes routines.(RoomCellGames.big_room_game), "changing a cell of the map of background :ground"
  end

  def test_a_pack_room_of_its_own_size_keeps_its_told_cell_through_scrolling
    Dir.mktmpdir do |folder|
      program, = told_slot_areas_game_and_file(areas_original(folder), across: ACROSS_BY_AREA) do |world|
        RoomCellGames.emit_pack_room_walk(self, world)
      end

      assert_backends_agree(program, frames: MOMENT_FRAMES)
    end
  end

  def test_a_told_cell_of_a_second_area_of_its_own_tiles_is_that_areas_picture
    Dir.mktmpdir do |folder|
      program, = told_slot_areas_game_and_file(areas_original(folder))

      assert_backends_agree(program, frames: [TOLD_TOWN_PASS + 2, TOLD_CASTLE_PASS + 2])
    end
  end
end
