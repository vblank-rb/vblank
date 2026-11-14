# frozen_string_literal: true

require "test_helper"

# The small games these tests play, kept once for this file, for the queue's own limit on the
# Advance (test/console/gba/vblank/dsl/test_held_tiles_on_the_advance.rb), and for the same games
# played on the Advance's cartridge (test/lowering/gba/vblank/dsl/test_held_tiles_cartridge.rb).
module HeldTilesGames
  COLS = 30      # a message box across the screen...
  ROWS = 8       # ...and eight cells down: 240 cells, which the Advance's cartridge is held to
  # ...and two rows of it, 60 cells, on every run: the Color writes about 60 in the gap. (A
  # Genesis writes 256 there, Console::GenesisAnswers, `background`.)
  ALL_RUNS_ROWS = 2
  OPEN_AT = 3 # the pass that opens the one cell

  # A box of red cells, whose cell (3, 1) turns blue on pass OPEN_AT. +held+ is the setting under test.
  private def one_cell_game(held:)
    proc do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:floor, "#" => :blue) { Minitest::Test::SOLID_TILE }
      tiles :frame, "#" => :wall, "." => :floor
      box = background :box, tiles: :frame, map: Array.new(HeldTilesGames::ROWS) { "#" * HeldTilesGames::COLS },
                             held: held
      frames = var :frames, 0
      game_loop do
        frames += 1
        box.set_tile 3, 1, "." if frames == HeldTilesGames::OPEN_AT
      end
    end
  end

  # A box that opens a column a pass: each pass writes every cell of its +rows+, blue left of column
  # p and red from there on, as a message box rewrites every cell of the size it grows to. +busy+
  # passes of a counting loop come first, so the cells are written late in the pass, while the
  # display draws. The box opens to the full width and starts again.
  private def growing_box_game(held: true, busy: 0, rows: HeldTilesGames::ALL_RUNS_ROWS)
    proc do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:floor, "#" => :blue) { Minitest::Test::SOLID_TILE }
      tiles :frame, "#" => :wall, "." => :floor
      box = background :box, tiles: :frame, map: Array.new(HeldTilesGames::ROWS) { "#" * HeldTilesGames::COLS },
                             held: held
      size = var :size, 0
      spin = var :spin, 0
      game_loop do
        size += 1
        size.store! 1 if size > HeldTilesGames::COLS
        repeat(busy) { spin += 1 } if busy.positive?
        repeat(rows) do |row|
          repeat(HeldTilesGames::COLS) do |col|
            if col < size
              box.set_tile col, row, "."
            else
              box.set_tile col, row, "#"
            end
          end
        end
      end
    end
  end

  # A held box every screen shows, as a HUD is, and two scenes with a background each, as rooms
  # are. On pass OPEN_AT the box's cell (3, 1) turns blue and then, later in the same pass, the
  # second scene takes over and puts its own background up. The rooms cover only the top-left
  # two cells, so the box's cell is in view in both.
  private def scene_change_game
    proc do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:floor, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:grass, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :frame, "#" => :wall, "." => :floor
      tiles :room, "g" => :grass
      hud = background :hud, tiles: :frame, map: Array.new(HeldTilesGames::ROWS) { "#" * HeldTilesGames::COLS },
                             held: true
      scene(:first) { background :first_room, tiles: :room, map: ["gg"] }
      scene(:second) { background :second_room, tiles: :room, map: ["gg"] }
      frames = var :frames, 0
      state = var :state, 0
      game_loop do
        frames += 1
        if frames == HeldTilesGames::OPEN_AT
          hud.set_tile 3, 1, "."
          state.store! 1
        end
        case_var(:state) do
          when_val 0, :first
          when_val 1, :second
        end
      end
    end
  end

  # A held room on a tiled screen and a scene on a painted one. On pass OPEN_AT a cell of the room
  # changes and then, later in the same pass, the painted scene takes over and paints its picture
  # once. The painted picture lives in the video memory the room's map was in, so a change still
  # waiting there would land in it.
  private def painted_scene_game
    proc do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:floor, "#" => :blue) { Minitest::Test::SOLID_TILE }
      tiles :frame, "#" => :wall, "." => :floor
      frames = var :frames, 0
      state = var :state, 0
      painted = var :painted, 0
      scene(:room) do
        room = background :room, tiles: :frame, map: Array.new(HeldTilesGames::ROWS) { "#" * HeldTilesGames::COLS },
                                 held: true
        if frames == HeldTilesGames::OPEN_AT
          room.set_tile 3, 1, "."
          state.store! 1
        end
      end
      scene(:paint) do
        screen :bitmap
        if painted == 0
          clear_screen :green
          painted.store! 1
        end
      end
      game_loop do
        frames += 1
        # Two choices, so the painted scene arrives in the pass the room's cell changed.
        case_var(:state) { when_val 0, :room }
        case_var(:state) { when_val 1, :paint }
      end
    end
  end

  # One pass that makes more changes than the queue for the boundary holds: cell (0, 0) goes blue
  # again and again, then green, and only after all of those cell (1, 0) goes blue.
  private def overflowing_game
    proc do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:floor, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:grass, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :frame, "#" => :wall, "." => :floor, "g" => :grass
      box = background :box, tiles: :frame, map: Array.new(HeldTilesGames::ROWS) { "#" * HeldTilesGames::COLS },
                             held: true
      frames = var :frames, 0
      game_loop do
        frames += 1
        if frames == 1
          repeat(VBlank::IR::Nodes::ShowHeldTiles::MOST_CELLS + 6) { box.set_tile 0, 0, "." }
          box.set_tile 0, 0, "g"
          box.set_tile 1, 0, "."
        end
      end
    end
  end

  private def cell_color(screen, col, row) = screen.pixel((col * 8) + 4, (row * 8) + 4)

  # The blue cells' columns on row +row+ of +screen+.
  private def blue_columns(screen, row)
    (0...HeldTilesGames::COLS).select { |col| cell_color(screen, col, row) == VBlank::Graphics::Color.resolve(:blue) }
  end

  private def tree_of(source)
    builder = VBlank::Builder.new
    builder.instance_eval(&source)
    builder.finalize_program
    builder.program
  end

  # At every frame boundary after the first, the pass number the game holds in +counter+ and what
  # the block reads off the picture.
  private def boundary_pairs(source, frames: 6, counter: :frames)
    player = game_player
    pairs = []
    player.each_vblank do |frame|
      pairs << [player[counter], yield(player.screen)] if frame > 1
    end
    player.run(tree_of(source), frames: frames)
    refute_empty pairs
    pairs
  end
end

# A BACKGROUND WHOSE CELL CHANGES ALL SHOW ON ONE FRAME.
#
# Without `held: true` a cell is written where the game says, and the display, which reads the map
# as it draws, shows it on this frame or the next by how far down the screen it has got. With it,
# every `set_tile` of a pass waits, and they all show on the next frame, as the framework's other
# drawing does: a sprite, a scroll, a map handed over. So a test reads the picture
# `framework_drawing_lag` passes behind the numbers, as it does for a sprite.
class TestHeldTiles < Minitest::Test
  include HeldTilesGames

  def test_a_held_change_shows_on_the_frame_a_sprite_moved_with_it_would
    pairs = boundary_pairs(one_cell_game(held: true)) { |screen| cell_color(screen, 3, 1) == Color.resolve(:blue) }
    pairs.each do |frames, open|
      assert_equal frames - framework_drawing_lag >= OPEN_AT, open, "pass #{frames}: the cell shows open: #{open}"
    end
    assert(pairs.any? { |_, open| open }, "the cell opened in the end")
  end

  def test_a_change_not_held_shows_with_the_pass_that_made_it
    boundary_pairs(one_cell_game(held: false)) { |screen| cell_color(screen, 3, 1) == Color.resolve(:blue) }.each do |frames, open|
      assert_equal frames >= OPEN_AT, open, "pass #{frames}: the cell shows open: #{open}"
    end
  end

  # Every frame shows one whole size of the box, never part of two, and the size of the pass it is
  # drawn from.
  def test_every_frame_shows_all_of_one_pass_and_none_of_the_next
    pairs = boundary_pairs(growing_box_game, frames: 8, counter: :size) do |screen|
      (0...ALL_RUNS_ROWS).map { |row| blue_columns(screen, row) }
    end
    pairs.each do |size, rows|
      shown = size - framework_drawing_lag
      rows.each_with_index do |columns, row|
        assert_equal (0...shown).to_a, columns, "pass #{size}, row #{row}: the box is #{shown} columns wide"
      end
    end
  end

  # --- friendly errors ---

  def test_held_that_is_not_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) { tree_of(held_setting_game(:tiled, "yes")) }
    assert_match(/:box/, error.message)
    assert_match(/true or false/, error.message)
  end

  def test_held_on_a_bitmap_screen_is_a_friendly_error
    error = assert_raises(ArgumentError) { tree_of(held_setting_game(:bitmap, true)) }
    assert_match(/:box/, error.message)
    assert_match(/screen :bitmap/, error.message)
  end

  def test_held_in_one_scene_and_not_another_is_a_friendly_error
    error = assert_raises(ArgumentError) { tree_of(held_in_one_scene_game) }
    assert_match(/:box/, error.message)
    assert_match(/every declaration/, error.message)
  end

  private

  def held_setting_game(screen_kind, held)
    proc do
      screen screen_kind
      image(:wall, "#" => :red) { SOLID_TILE }
      tiles :frame, "#" => :wall
      background :box, tiles: :frame, map: ["##"], held: held
      game_loop {}
    end
  end

  def held_in_one_scene_game
    proc do
      screen :tiled
      image(:wall, "#" => :red) { SOLID_TILE }
      tiles :frame, "#" => :wall
      state = var :state, 0
      scene(:first) { background :box, tiles: :frame, map: ["##"], held: true }
      scene(:second) { background :box, tiles: :frame, map: ["##"] }
      game_loop do
        case_var(:state) do
          when_val 0, :first
          when_val 1, :second
        end
        state.store! 1
      end
    end
  end
end

# A SCENE TAKING OVER FORGETS ONLY THE CHANGES WAITING FOR ITS OWN BACKGROUNDS. A box every screen
# shows, changed earlier in the pass a scene takes over in, still shows the change on the next
# frame. Played on each console that shows a scene's background beside a box every screen shows
# (the Color shows one background at a time): test/console/<console>/vblank/dsl/.
module HeldTilesSceneTests
  include HeldTilesGames

  def test_a_scene_taking_over_keeps_a_held_change_to_another_background
    pairs = boundary_pairs(scene_change_game) { |screen| cell_color(screen, 3, 1) == VBlank::Graphics::Color.resolve(:blue) }
    pairs.each do |frames, open|
      assert_equal frames - framework_drawing_lag >= HeldTilesGames::OPEN_AT, open, "pass #{frames}: the cell shows open: #{open}"
    end
    assert(pairs.any? { |_, open| open }, "the cell opened in the end")
  end
end
