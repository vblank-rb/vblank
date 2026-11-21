# frozen_string_literal: true

require "test_helper"
require "differential"
require "all/vblank/dsl/test_background_room_cells"

# A cell of a room changed while the game runs, on the Advance's cartridge, read in the emulator.
# What it shows on every run is in test/all/vblank/dsl/test_background_room_cells.rb. A map the
# cartridge brings into view a strip at a time keeps the changed cell as the view moves, and a
# cell of a second area of its own tiles is that area's picture.
class TestBackgroundRoomCellsCartridge < Minitest::Test
  include RoomCellGames
  include Differential

  # The frames each moment of the walk is read at.
  MOMENT_FRAMES = MOMENTS.map(&:first).freeze
  # A room of more cells than one piece of the copy of a changed map: three pieces.
  BIG_ACROSS = 256
  BIG_DOWN = 128
  # A frame's lines, and a line's cycles (GBATEK, "LCD Dimensions and Timings").
  FRAME_LINES = 228
  LINE_CYCLES = 1232

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

  # A changed map of more cells than one copy of the copying engine may move is copied in pieces,
  # and keeps its changed cell through scrolling as a smaller one does.
  def test_a_changed_map_bigger_than_one_copy_keeps_its_changed_cell_through_scrolling
    program = RoomCellGames.big_room_game(across: BIG_ACROSS, down: BIG_DOWN)

    assert_backends_agree(program, frames: [OPEN_IN_HALL, SCROLL_AWAY, SCROLL_BACK].map { |pass| pass + SETTLED })
  end

  # A piece of the copy holds the screen's interrupt off no longer than the mixer can wait. The
  # copy is made in the gap after show_map, and how long it takes is measured in the emulator: the
  # line the next pass starts on, against the same game that changes no cell and so copies nothing.
  # A piece is MapStreaming::KEPT_COPY_PIECE_CELLS of the cells measured. Its lines must be no more
  # than the mixer can wait (Mixer::LATE_ROOM), and the cycles a cell measured must be the ones the
  # piece is sized by (MapStreaming::KEPT_COPY_CYCLES_A_CELL), give or take the one line a reading
  # of the line can be off by.
  def test_a_piece_of_a_big_changed_map_copy_is_inside_the_mixers_late_room
    streaming = VBlank::IR::Backends::GBA::MapStreaming
    started = %i[changes unchanged].to_h { |kind| [kind, line_after_big_map_shown(changes: kind == :changes)] }
    copy_lines = (started[:changes] - started[:unchanged]) % FRAME_LINES
    cells = BIG_ACROSS * BIG_DOWN
    piece_lines = copy_lines * streaming::KEPT_COPY_PIECE_CELLS / cells.to_f
    late_lines = VBlank::IR::Backends::GBA::Mixer::LATE_ROOM / LINE_CYCLES.to_f

    assert_operator copy_lines, :>, 0, "the copy of #{cells} cells is made in the gap after show_map"
    assert_operator piece_lines, :<=, late_lines,
                    "the copy of #{cells} cells took #{copy_lines} lines, so a piece takes #{piece_lines.round(1)}, " \
                    "past the #{late_lines.round(1)} the mixer can wait"
    assert_in_delta streaming::KEPT_COPY_CYCLES_A_CELL * cells, copy_lines * LINE_CYCLES, LINE_CYCLES,
                    "the copy's cycles, measured, against the cycles a cell the piece is sized by"
  end

  # The line the pass after show_map hands over one of two maps of BIG_ACROSS by BIG_DOWN cells
  # starts on, read in the emulator. With +changes+ the game changes a cell later, so the gap
  # copies the map it hands over.
  private def line_after_big_map_shown(changes:)
    maps = %i[hall pit].each_with_index.to_h do |room, at|
      [room, Array.new(BIG_DOWN) { |row| Array.new(BIG_ACROSS) { |col| ".#"[(col + row + at) % 2] }.join }]
    end
    rom = VBlank.build("BIGCOPY", console: :gba, validate: false, out: StringIO.new, err: StringIO.new) do
      extend VBlank::Builder::Debug
      screen :tiled
      RoomCellGames.declare_room_tiles(self)
      ground = background :ground, tiles: :house_tiles, map: maps
      pass = var :pass, 0
      line = var :line, 0
      game_loop do
        pass += 1
        line = read_scanline if pass == 4
        ground.show_map 1 if pass == 3
        ground.set_tile 1, 1, "o" if changes && pass == 20
      end
    end
    assert_emulator_loads_rom(rom, frames: 8).var(:line)
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
