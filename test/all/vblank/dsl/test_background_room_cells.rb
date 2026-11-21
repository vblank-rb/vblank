# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_pack_background_areas"

# A cell of a room changed while the game runs (Background#set_tile), on a background walking
# between areas whose rooms are maps of different sizes: a chest that opens. The change shows on
# the frame written, stays as the view scrolls the cell out and back in, and lasts until `show_map`
# puts that room up again, the way a console's own game keeps a room's cells in work memory and
# brings them into view from there.
#
# The answer key is the same rooms drawn with the chest already open in the map, walked and
# scrolled by the same loop: that game writes no cell, so it shows only what a map holds.
module RoomCellGames
  include PackBackgroundAreaGames

  # The hall is wider and taller than the screen, so a scroll takes its chest out of view; the pit
  # is smaller. Maps of two sizes are brought into view a strip at a time where a console cannot
  # hold every map whole.
  HALL = Array.new(24) { |row| Array.new(40) { |col| row.zero? || col.zero? ? "#" : "." }.join }.freeze
  PIT = Array.new(12) { |row| Array.new(20) { |col| (row + col).even? ? "#" : "." }.join }.freeze
  # The chest in each room, [col, row]: shut ("c") in the map. Open ("o") is in no map.
  HALL_CHEST = [3, 2].freeze
  PIT_CHEST = [5, 4].freeze

  # The passes the loop (#emit_room_walk) acts on, and how many passes later the picture is read.
  OPEN_IN_HALL = 2
  SCROLL_AWAY = 4
  SCROLL_BACK = 7
  WALK_TO_PIT = 10
  OPEN_IN_PIT = 12
  WALK_BACK = 15
  SETTLED = 2

  # Each moment of the walk: [frames, the rooms whose chest the map shows open then, what].
  MOMENTS = [
    [OPEN_IN_HALL + SETTLED, [:hall], "the hall's chest open"],
    [SCROLL_AWAY + SETTLED, [:hall], "the chest scrolled out of view"],
    [SCROLL_BACK + SETTLED, [:hall], "the chest scrolled back into view, still open"],
    [OPEN_IN_PIT + SETTLED, [:pit], "the pit's chest open"],
    [WALK_BACK + SETTLED, [], "the hall put up again, its chest shut"]
  ].freeze

  # Each area's tiles: a floor, a wall, a shut chest and an open one, the cave's in other colours.
  AREA_COLORS = { house: %i[green blue yellow red], cave: %i[gray magenta cyan orange] }.freeze
  # Each tile's rows, "#" its first colour and "." its second.
  TILE_ROWS = { floor: (["#" * 8] * 8).join("\n"), wall: (["##..##.."] * 8).join("\n"),
                shut: ((["#" * 8] * 4) + (["." * 8] * 4)).join("\n"), open: (["#.#.#.#."] * 8).join("\n") }.freeze
  # The cells the pack game (#emit_pack_room_walk) writes, by area: [[col, row], place of the slot].
  PACK_WRITES = { town: [[0, 0], 1], castle: [[3, 0], 0] }.freeze

  VBlank::Testing::InRactors.share_constants(self)

  # Both rooms' maps, by room, each chest shut, or open in the rooms of +opened+. With +same_size+
  # the pit is the hall's size, so every map is one size and a console holds it whole.
  def self.room_maps(opened: [], same_size: false)
    pit = same_size ? Array.new(HALL.length) { |row| Array.new(HALL.first.length) { |col| (row + col).even? ? "#" : "." }.join } : PIT
    { hall: [HALL, HALL_CHEST], pit: [pit, PIT_CHEST] }.to_h do |room, (map, (col, row))|
      rows = map.map(&:dup)
      rows[row][col] = opened.include?(room) ? "o" : "c"
      [room, rows]
    end
  end

  def self.declare_room_tiles(builder)
    builder.instance_eval do
      AREA_COLORS.each do |area, (floor, wall, shut, open)|
        image(:"#{area}_floor", "#" => floor) { TILE_ROWS[:floor] }
        image(:"#{area}_wall", "#" => wall, "." => floor) { TILE_ROWS[:wall] }
        image(:"#{area}_shut", "#" => shut, "." => wall) { TILE_ROWS[:shut] }
        image(:"#{area}_open", "#" => open, "." => wall) { TILE_ROWS[:open] }
        tiles :"#{area}_tiles", "." => :"#{area}_floor", "#" => :"#{area}_wall", "c" => :"#{area}_shut", "o" => :"#{area}_open"
      end
    end
  end

  # The game: the hall in the house's tiles and the pit in the cave's, one background walking
  # between them. With +writes+ it opens each chest with set_tile; without, +opened+ names the
  # rooms whose map holds the chest open already (the answer key).
  def self.baked_rooms_game(writes: true, opened: [], same_size: false)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      RoomCellGames.declare_room_tiles(self)
      maps = RoomCellGames.room_maps(opened: opened, same_size: same_size)
      rooms = background :rooms, tiles: { house: :house_tiles, cave: :cave_tiles },
                                 map: { house: { hall: maps[:hall] }, cave: { pit: maps[:pit] } }
      opener = (->((col, row)) { rooms.set_tile col, row, "o" } if writes)
      RoomCellGames.emit_room_walk(self, rooms, opener)
    end
    b.finalize_program
    b.program
  end

  # The loop: open the hall's chest, scroll it out of view and back, walk to the pit and open its
  # chest, then walk back to the hall. +open+ is called with a chest's [col, row], or is nil for a
  # game that writes nothing.
  def self.emit_room_walk(builder, rooms, open)
    builder.instance_eval do
      pass = var :pass, 0
      game_loop do
        pass += 1
        open&.call(HALL_CHEST) if pass == OPEN_IN_HALL
        rooms.scroll_to 200, 0 if pass == SCROLL_AWAY
        rooms.scroll_to 0, 0 if pass == SCROLL_BACK
        rooms.show_map :pit if pass == WALK_TO_PIT
        open&.call(PIT_CHEST) if pass == OPEN_IN_PIT
        rooms.show_map :hall if pass == WALK_BACK
      end
    end
  end

  # One room of 80x20 CELLS, more than any console's grid holds: its chest opened with set_tile on
  # OPEN_IN_HALL, or, without +writes+, open in the map already; scrolled away and back. +across+
  # and +down+ make the room another size.
  def self.big_room_game(writes: true, across: 80, down: 20)
    chest = writes ? "c" : "o"
    map = Array.new(down) { |row| Array.new(across) { |col| [col, row] == HALL_CHEST ? chest : ".#"[(col + row) % 2] }.join }
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      RoomCellGames.declare_room_tiles(self)
      ground = background :ground, tiles: :house_tiles, map: map
      pass = var :pass, 0
      game_loop do
        pass += 1
        ground.set_tile(*HALL_CHEST, "o") if writes && pass == OPEN_IN_HALL
        ground.scroll_to 400, 0 if pass == SCROLL_AWAY
        ground.scroll_to 0, 0 if pass == SCROLL_BACK
      end
    end
    b.finalize_program
    b.program
  end

  # The same big room with a row of cells opened in a loop (`repeat`), each pass: the first
  # LOOPED_CELLS cells of row 2. Without +writes+ the map holds them open already.
  LOOPED_CELLS = 6

  def self.big_room_looped_game(writes: true)
    map = Array.new(20) do |row|
      Array.new(80) { |col| !writes && row == 2 && col < LOOPED_CELLS ? "o" : ".#"[(col + row) % 2] }.join
    end
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      RoomCellGames.declare_room_tiles(self)
      ground = background :ground, tiles: :house_tiles, map: map
      count = var :count, 0
      opening = lambda do
        repeat LOOPED_CELLS do |at|
          ground.set_tile at, 2, "o"
          count += 1
        end
      end
      game_loop do
        opening.call if writes
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # The same from the data pack: the town's map two cells across and the castle's four, so of two
  # sizes, each a slot of map cells, and the cells told by a slot (#told_slot_areas_game_and_file).
  # The town's top left takes place 1 on OPEN_IN_HALL, the view goes off the map and back, the
  # castle's last cell takes place 0 on OPEN_IN_PIT, and the town comes up again on WALK_BACK.
  def self.emit_pack_room_walk(builder, world, writes: true)
    builder.instance_eval do
      pass = var :pass, 0
      game_loop do
        pass += 1
        (town_at, town_place), (castle_at, castle_place) = PACK_WRITES.values
        world.set_tile(*town_at, town_place) if writes && pass == OPEN_IN_HALL
        world.scroll_to 64, 0 if pass == SCROLL_AWAY
        world.scroll_to 0, 0 if pass == SCROLL_BACK
        world.show_map :castle if pass == WALK_TO_PIT
        world.set_tile(*castle_at, castle_place) if writes && pass == OPEN_IN_PIT
        world.show_map :town if pass == WALK_BACK
      end
    end
  end

  # AREAS with the cell each of +written+ (area names) writes in PACK_WRITES already in its map.
  def self.areas_written(written)
    AREAS.to_h do |name, area|
      (col, row), place = PACK_WRITES.fetch(name)
      at = (row * ACROSS_BY_AREA.fetch(name)) + col
      cells = area.cells.each_with_index.map { |cell, k| written.include?(name) && k == at ? TOLD_PLACES.fetch(place) : cell }
      [name, area.with(cells: cells)]
    end
  end
end

class TestBackgroundRoomCells < Minitest::Test
  include RoomCellGames

  private def screen_at(program, frames) = game_player.run(program, frames: frames).screen.to_a

  def test_a_cell_of_a_room_changed_stays_through_scrolling_until_the_room_is_put_up_again
    written = RoomCellGames.baked_rooms_game
    MOMENTS.each do |frames, opened, what|
      assert_equal screen_at(RoomCellGames.baked_rooms_game(writes: false, opened: opened), frames), screen_at(written, frames), what
    end
  end

  # Rooms of one size, which a console holds whole: the tile named is the area's own.
  def test_a_cell_of_a_room_in_each_area_takes_the_tile_of_the_area_showing
    written = RoomCellGames.baked_rooms_game(same_size: true)
    MOMENTS.each do |frames, opened, what|
      answer = RoomCellGames.baked_rooms_game(writes: false, opened: opened, same_size: true)

      assert_equal screen_at(answer, frames), screen_at(written, frames), what
    end
  end

  # A background from the data pack: set_tile names a place of the slot the cells were told by.
  def test_a_cell_of_a_pack_room_told_by_a_slot_stays_through_scrolling_until_the_room_is_put_up_again
    Dir.mktmpdir do |folder|
      written, = told_slot_areas_game_and_file(areas_original(folder), across: ACROSS_BY_AREA) do |world|
        RoomCellGames.emit_pack_room_walk(self, world)
      end
      { OPEN_IN_HALL + SETTLED => [[:town], "the town's cell written"],
        SCROLL_BACK + SETTLED => [[:town], "scrolled off the map and back, still written"],
        OPEN_IN_PIT + SETTLED => [[:castle], "the castle's cell written"],
        WALK_BACK + SETTLED => [[], "the town put up again as its map holds it"] }.each do |frames, (areas, what)|
        answer = areas_drawn_by_hand(RoomCellGames.areas_written(areas), across: ACROSS_BY_AREA) do |world|
          RoomCellGames.emit_pack_room_walk(self, world, writes: false)
        end

        assert_equal screen_at(answer, frames), screen_at(written, frames), what
      end
    end
  end

  # set_cell is the name a pack game already writes the same call with.
  def test_set_cell_writes_a_pack_room_as_set_tile_does
    Dir.mktmpdir do |folder|
      from = areas_original(folder)
      with_set_tile, = told_slot_areas_game_and_file(from) { |world| game_loop { world.set_tile 1, 0, 1 } }
      with_set_cell, = told_slot_areas_game_and_file(from) { |world| game_loop { world.set_cell 1, 0, 1 } }

      assert_equal screen_at(with_set_cell, 3), screen_at(with_set_tile, 3)
    end
  end

  # One map bigger than any grid a console holds, written and scrolled out of view and back.
  def test_a_cell_of_a_map_too_big_to_hold_whole_stays_through_scrolling
    written = RoomCellGames.big_room_game
    [OPEN_IN_HALL, SCROLL_AWAY, SCROLL_BACK].each do |pass|
      answer = RoomCellGames.big_room_game(writes: false)

      assert_equal screen_at(answer, pass + SETTLED), screen_at(written, pass + SETTLED), "pass #{pass}"
    end
  end

  # A loop keeps its count where a console keeps it; changing a cell inside it changes each cell.
  def test_cells_of_a_map_too_big_to_hold_whole_changed_in_a_loop_are_each_changed
    assert_equal screen_at(RoomCellGames.big_room_looped_game(writes: false), 4), screen_at(RoomCellGames.big_room_looped_game, 4)
  end

  def test_a_tile_no_area_holds_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      b = VBlank::Builder.new
      b.instance_eval do
        screen :tiled
        RoomCellGames.declare_room_tiles(self)
        maps = RoomCellGames.room_maps
        rooms = background :rooms, tiles: { house: :house_tiles, cave: :cave_tiles },
                                   map: { house: { hall: maps[:hall] }, cave: { pit: maps[:pit] } }
        rooms.set_tile 1, 1, "?"
      end
    end

    assert_includes error.message, "\"?\""
  end
end
