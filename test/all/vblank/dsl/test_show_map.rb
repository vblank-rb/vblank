# frozen_string_literal: true

require "test_helper"
require "differential"

# A background is handed a whole different map, while the game runs.
#
# `set_tile` gave a background one cell changing at a time — a door, a pot, a bombable wall —
# and deliberately left the bulk case out, because the two are not the same problem. A cell is
# one half-word and can go in wherever the game is; a whole room is thousands of them, and put
# in the same way the screen would show half of the old room and half of the new.
#
# So a room is a map, and walking into one is naming it. `background :rooms, map: { hall: ...,
# cave: ... }` declares them and `rooms.show_map :cave` says which is showing; the copy happens
# in the gap between frames, and only on the frame the answer changed.
class TestShowMap < Minitest::Test
  include Differential

  # Two rooms over one tileset. HALL is all wall, CAVE all floor, so which one is showing is
  # readable off any pixel of the screen.
  HALL = Array.new(6) { "######" }
  CAVE = Array.new(6) { "......" }
  MIXED = ["######", "..####", "######", "######", "######", "######"]

  private def rooms_program(&steering)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: CAVE, mixed: MIXED }
      frames = 0
      game_loop do
        frames += 1
        instance_exec(rooms, frames, &steering)
      end
    end
    builder.finalize_program
    builder.program
  end

  private def pixel_at(cell_col, cell_row, screen)
    screen.pixel((cell_col * 8) + 4, (cell_row * 8) + 4)
  end

  private def cell_of(program, frames:, col: 1, row: 1)
    pixel_at(col, row, game_player.run(program, frames: frames).screen)
  end

  # --- the whole room changes ---

  def test_the_first_map_declared_is_the_one_showing_at_the_start
    program = rooms_program { |_rooms, _frames| nil }

    assert_equal Color.resolve(:red), cell_of(program, frames: 4), "the hall, which was declared first"
  end

  # A background whose line runs every pass keeps the map the game handed it: put up again, it shows
  # as it now is (Reference#put_up_background), as a room stays when the routine that draws the
  # screen runs each frame.
  def test_a_background_put_up_again_keeps_the_map_it_was_handed
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      frames = var :frames, 0
      func(:put_up_rooms) do
        rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: CAVE }
        rooms.show_map :cave if frames == 2
      end
      game_loop do
        call :put_up_rooms
        frames += 1
      end
    end
    builder.finalize_program

    assert_equal Color.resolve(:blue), cell_of(builder.program, frames: 6), "the cave stays"
  end

  # ...and a map bigger than a console's grid of cells, which some consoles keep whole in memory.
  BIG_HALL = Array.new(40) { "#" * 40 }
  BIG_CAVE = Array.new(40) { "." * 40 }

  def test_a_big_background_put_up_again_keeps_the_map_it_was_handed
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      frames = var :frames, 0
      func(:put_up_rooms) do
        rooms = background :rooms, tiles: :dungeon, map: { hall: BIG_HALL, cave: BIG_CAVE }
        rooms.show_map :cave if frames == 2
      end
      game_loop do
        call :put_up_rooms
        frames += 1
      end
    end
    builder.finalize_program

    assert_equal Color.resolve(:blue), cell_of(builder.program, frames: 6), "the cave stays"
  end

  # A background every screen shows keeps the map it was handed while scenes of no scenery of their
  # own take turns over it,
  def test_scenes_taking_turns_leave_the_map_handed_to_the_background_every_screen_shows
    assert_equal Color.resolve(:blue), cell_of(scene_turns_program(HALL, CAVE), frames: 9), "the cave stays"
  end

  # ...a map bigger than a console's grid too.
  def test_scenes_taking_turns_leave_the_big_map_handed_to_the_background_every_screen_shows
    assert_equal Color.resolve(:blue), cell_of(scene_turns_program(BIG_HALL, BIG_CAVE), frames: 9), "the cave stays"
  end

  # Rooms of +hall+ and +cave+ every screen shows, handed the cave on the second pass, under two scenes
  # with no scenery of their own that take turns.
  private def scene_turns_program(hall, cave)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      frames = var :frames, 0
      state = var :state, 0
      rooms = background :rooms, tiles: :dungeon, map: { hall: hall, cave: cave }
      scene(:play) { nil }
      scene(:pause) { nil }
      game_loop do
        rooms.show_map :cave if frames == 1
        state = 1 if frames == 3
        state = 0 if frames == 6
        call({ 0 => :play, 1 => :pause }, number: :state)
        frames += 1
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_naming_another_map_hands_the_background_that_whole_map
    program = rooms_program { |rooms, frames| rooms.show_map :cave if frames == 2 }

    assert_equal Color.resolve(:blue), cell_of(program, frames: 6), "every cell is the cave's floor"
  end

  def test_a_map_can_be_named_by_a_number_the_game_works_out
    program = rooms_program do |rooms, frames|
      where = var :where, 0
      where = 1 if frames == 2 # ...which is the cave, second of the three
      rooms.show_map where
    end

    assert_equal Color.resolve(:blue), cell_of(program, frames: 6)
  end

  def test_the_cells_a_map_actually_holds_are_the_ones_it_was_drawn_with
    program = rooms_program { |rooms, frames| rooms.show_map :mixed if frames == 2 }
    screen = game_player.run(program, frames: 6).screen

    assert_equal Color.resolve(:blue), pixel_at(0, 1, screen), "the two floor cells of row 1"
    assert_equal Color.resolve(:blue), pixel_at(1, 1, screen)
    assert_equal Color.resolve(:red), pixel_at(2, 1, screen), "and the wall beside them"
    assert_equal Color.resolve(:red), pixel_at(0, 0, screen), "and the wall above"
  end

  def test_a_game_can_walk_back_and_forth_between_maps
    program = rooms_program do |rooms, frames|
      rooms.show_map :cave if frames == 2
      rooms.show_map :hall if frames == 4
    end

    # The third pass's map, as far behind as the framework draws (Testing#framework_drawing_lag).
    assert_equal Color.resolve(:blue), cell_of(program, frames: 3 + framework_drawing_lag), "the cave on the way out"
    assert_equal Color.resolve(:red), cell_of(program, frames: 8), "and the hall again on the way back"
  end

  # Saying the map that is already showing costs nothing, which is what lets `show_map` be
  # written every frame — from a scene, from a branch — rather than only on the frame a door
  # is opened. Nothing observable changes either way; what this pins is that saying it over
  # and over draws the same picture as saying it once.
  def test_saying_the_same_map_every_frame_shows_that_map
    program = rooms_program { |rooms, _frames| rooms.show_map :cave }

    assert_equal Color.resolve(:blue), cell_of(program, frames: 6)
  end

  # A map number the game worked out can be anything at all, and then nothing happens — the
  # picture stays as it was rather than filling the cells with whatever followed the maps in
  # the cartridge. So a room number that ran off the end needs no test around it.
  def test_a_number_naming_no_map_leaves_the_picture_alone
    program = rooms_program do |rooms, frames|
      far = var :far, 900
      rooms.show_map far if frames == 2
      rooms.show_map(-3) if frames == 4
    end

    assert_equal Color.resolve(:red), cell_of(program, frames: 8), "still the hall"
  end

  # A cell changed with `set_tile` is part of this run, not part of the map — so the map that
  # comes back is the one that was drawn. A game that remembers an opened door opens it again
  # on the way in, which is where it wants that decision anyway.
  def test_a_map_comes_back_exactly_as_it_was_declared
    program = rooms_program do |rooms, frames|
      rooms.set_tile 1, 1, "." if frames == 2
      rooms.show_map :cave if frames == 4
      rooms.show_map :hall if frames == 6
    end

    assert_equal Color.resolve(:blue), cell_of(program, frames: 4), "the cell was opened"
    assert_equal Color.resolve(:red), cell_of(program, frames: 10), "and the hall came back whole"
  end

  # A program with no game loop has no gap between frames to hold the copy for, so the copy
  # happens where it was asked for — the same bargain `wait_vblank` and a scroll already
  # make outside a loop. Doing nothing at all there would be a silently unchanged screen,
  # which is the failure this framework exists to stop.
  def test_a_program_with_no_game_loop_still_gets_its_map
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: CAVE }
      rooms.show_map :cave
      halt
    end
    builder.finalize_program

    screen = game_player.run(builder.program, max_steps: 100_000).screen

    assert_equal Color.resolve(:blue), pixel_at(1, 1, screen)
  end

  # However many places a game says which map is showing, the copy happens once, and it
  # happens in the gap between frames. That is the whole of the acceptance: a copy where
  # `show_map` was called would land while the display was reading, and the screen would
  # show half of the old room and half of the new. There is nothing to read off a picture
  # afterwards — a torn frame is one frame, and the oracle has no display racing it — so
  # this reads where the copy landed instead.
  def test_the_copy_happens_once_a_frame_in_the_gap_between_frames
    program = rooms_program do |rooms, frames|
      rooms.show_map :cave if frames == 2
      rooms.show_map :mixed if frames == 4
      rooms.show_map :hall if frames == 6
    end

    copies = program.walk.select { |node| node.kind == :show_map }

    assert_equal 1, copies.length, "three places said which map, and there is one copy"

    loop_body = program.walk.find { |node| node.kind == :loop }.children
    wait = loop_body.index { |node| node.kind == :wait_vblank }
    at = loop_body.index { |node| node.walk.any? { |inner| inner.kind == :show_map } }

    assert wait, "the frame's wait is the anchor"
    assert_operator at, :>, wait, "and the copy is after it, in the gap the wait opens"
  end

  # --- reading it back ---

  def test_which_map_is_showing_reads_back_by_its_name
    program = rooms_program { |rooms, frames| rooms.show_map :mixed if frames == 2 }

    assert_equal :mixed, game_player.run(program, frames: 6).background(:rooms).map
  end

  def test_a_map_declared_by_name_has_a_number_to_compare_against
    builder = Builder.new
    rooms = nil
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      tiles :dungeon, "#" => :wall
      rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: HALL, mixed: HALL }
    end

    assert_equal 0, rooms.map_number(:hall)
    assert_equal 2, rooms.map_number(:mixed)
    assert_equal 3, rooms.map_count
  end

  def test_a_program_can_branch_on_which_room_it_is_in
    program = rooms_program do |rooms, frames|
      here = var :here, 0
      rooms.show_map :cave if frames == 2
      here = 7 if rooms.showing == rooms.map_number(:cave)
    end

    assert_equal 7, game_player.run(program, frames: 6)[:here]
  end

  # --- the console draws the same thing ---

  def test_both_backends_agree_after_a_map_changed
    assert_backends_agree(rooms_program { |rooms, frames| rooms.show_map :mixed if frames == 2 },
                          frames: 6)
  end

  def test_both_backends_agree_walking_back_and_forth
    program = rooms_program do |rooms, frames|
      rooms.show_map :cave if frames == 2
      rooms.show_map :mixed if frames == 4
      rooms.show_map :hall if frames == 6
    end
    assert_backends_agree(program, frames: 9)
  end

  def test_both_backends_agree_on_a_number_the_game_worked_out
    program = rooms_program do |rooms, frames|
      where = var :where, 0
      where = 2 if frames == 3
      rooms.show_map where
    end
    assert_backends_agree(program, frames: 7)
  end

  # A map wider than 32 cells is stored as two squares side by side rather than as rows of the
  # whole width, so the whole map has to be re-laid the same way — a copy that simply walked
  # the authored rows would put the right half in the wrong place.
  private def wide_rooms_program
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      left = Array.new(32) { ("#" * 32) + ("." * 32) }
      right = Array.new(32) { ("." * 32) + ("#" * 32) }
      rooms = background :rooms, tiles: :dungeon, map: { left: left, right: right }
      frames = 0
      game_loop do
        frames += 1
        rooms.show_map :right if frames == 2
        rooms.scroll_to 256, 0
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_a_wide_maps_second_square_is_handed_over_too
    screen = game_player.run(wide_rooms_program, frames: 6).screen

    assert_equal Color.resolve(:red), pixel_at(3, 1, screen),
                 "column 35, seen from a scroll of 256, is wall in the map that was handed over"
  end

  def test_both_backends_agree_on_a_wide_map
    assert_backends_agree(wide_rooms_program, frames: 6)
  end

  # A game with a lot of rooms is the point of this, so the far end of a long set is worth
  # its own test: the map is found by counting strides from the first, and a stride that was
  # a little wrong would still land inside the blob and draw a plausible neighbouring room.
  # The last of thirty-two is where that shows.
  private def many_rooms_program(pick)
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:floor, "#" => :blue) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, "." => :floor
      # Room N has one floor cell, at a spot only room N puts it, so which room is showing is
      # readable off the screen and a neighbouring room looks different from the right one.
      maps = (0...32).to_h do |n|
        rows = Array.new(6) { "#" * 32 }
        col = n % 8
        rows[1 + (n / 8)] = ("#" * col) + "." + ("#" * (31 - col))
        [:"room#{n}", rows]
      end
      rooms = background :rooms, tiles: :dungeon, map: maps
      frames = 0
      game_loop do
        frames += 1
        rooms.show_map pick if frames == 2
      end
    end
    builder.finalize_program
    builder.program
  end

  def test_the_last_of_many_rooms_is_the_one_that_comes_up
    screen = game_player.run(many_rooms_program(31), frames: 6).screen

    assert_equal Color.resolve(:blue), pixel_at(7, 4, screen), "room 31's floor cell"
    assert_equal Color.resolve(:red), pixel_at(6, 4, screen), "and not room 30's"
    assert_equal Color.resolve(:red), pixel_at(7, 3, screen), "nor room 23's"
  end

  def test_both_backends_agree_on_the_last_of_many_rooms
    assert_backends_agree(many_rooms_program(31), frames: 6)
  end

  # --- friendly errors ---

  def test_a_background_with_one_map_says_how_to_declare_several
    error = assert_raises(ArgumentError) do
      builder = Builder.new
      builder.instance_eval do
        screen :tiled
        image(:wall, "#" => :red) { SOLID_TILE }
        tiles :dungeon, "#" => :wall
        room = background :room, tiles: :dungeon, map: HALL
        game_loop { room.show_map :cave }
      end
    end
    assert_match(/:room/, error.message)
    assert_match(/one map/, error.message)
    assert_match(/show_map/, error.message, "it says what the other kind looks like")
  end

  def test_a_map_the_background_does_not_have_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      builder = Builder.new
      builder.instance_eval do
        screen :tiled
        image(:wall, "#" => :red) { SOLID_TILE }
        tiles :dungeon, "#" => :wall
        rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: HALL }
        game_loop { rooms.show_map :attic }
      end
    end
    assert_match(/:attic/, error.message, "it names what was asked for")
    assert_match(/:hall/, error.message, "and what it can be")
  end

  def test_handing_a_bitmap_background_another_map_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      builder = Builder.new
      builder.instance_eval do
        screen :bitmap
        image(:wall, "#" => :red) { SOLID_TILE }
        tiles :dungeon, "#" => :wall
        rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: HALL }
        game_loop { rooms.show_map :cave }
      end
    end
    assert_match(/screen :bitmap/, error.message)
    assert_match(/blit/, error.message, "it says what to do instead")
  end

  # `blocked_by` used to be refused here, because it read the walls once while the program
  # was built and would have held the first room's walls in every room. It reads the grid of
  # the map that is really showing now, so a mover is stopped by the walls of the room it is
  # standing in — see test_room_walls.rb for the behaviour.
  def test_a_background_with_several_maps_can_be_blocked_by
    builder = Builder.new
    builder.instance_eval do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      image(:hero, "#" => :white) { SOLID_TILE }
      tiles :dungeon, "#" => :wall, solid: ["#"]
      rooms = background :rooms, tiles: :dungeon, map: { hall: HALL, cave: HALL }
      sprite(:hero, at: [8, 8]).blocked_by(rooms)
    end

    refute_nil builder.program
  end

  def test_a_background_given_an_empty_set_of_maps_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      builder = Builder.new
      builder.instance_eval do
        screen :tiled
        image(:wall, "#" => :red) { SOLID_TILE }
        tiles :dungeon, "#" => :wall
        background :rooms, tiles: :dungeon, map: {}
      end
    end
    assert_match(/:rooms/, error.message)
  end
end
