# frozen_string_literal: true

require "test_helper"
require "differential"

# A background whose map is bigger than the console's grid — wider or taller than 64 cells,
# which is a room four screens across and more. The console holds a grid of at most 64x64
# cells for a layer, so the framework keeps the whole map in the cartridge and copies in the
# cells coming into view as the view moves. Nothing in the program says so: the map is
# written at its size and scrolled like any other.
#
# How many cells the Advance's cartridge copies to put a view up, measured by its profiler, is in
# test/lowering/gba/vblank/builder/test_big_maps_cartridge.rb.

# The maps and games both files play. The game blocks call back through `test = self`, so those
# helpers are public.
module BigMapsGames
  KEYS = %w[r g b w].freeze

  private def program(&block)
    b = VBlank::Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A map with no pattern that repeats every 32 or 64 cells, so a column or row left over
  # from another part of the map, or copied to the wrong place, shows as the wrong colour.
  # With +holes+ two cells in three are empty, for a layer the one behind shows through.
  def scrambled(cols, rows, seed: 7, holes: false)
    random = Random.new(seed)
    Array.new(rows) do
      Array.new(cols) { holes && random.rand(3).positive? ? " " : KEYS[random.rand(KEYS.size)] }.join
    end
  end

  def tileset(builder)
    builder.instance_eval do
      image(:r, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:g, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:b, "#" => :blue) { (["#" * 8] * 8).join("\n") }
      image(:w, "#" => :white, "." => :red) { (["####...."] * 4 + ["#" * 8] * 4).join("\n") }
      tiles :ground, "r" => :r, "g" => :g, "b" => :b, "w" => :w
    end
  end

  # A scene's first takeover, named at the end of the pass before — as a file screen does on START.
  # A menu for ten passes, which names the playing scene at the end of its tenth. The playing scene
  # owns a big room and puts its view 5 columns and 3 rows from the corner from its first pass.
  def named_at_the_end_of_a_pass(builder)
    test = self
    builder.instance_eval do
      screen :tiled
      test.tileset(self)
      pass = 0
      mode = var :mode, 0
      scene(:menu) { nil }
      scene(:playing) do
        ground = background :ground, tiles: :ground, map: test.scrambled(100, 90)
        ground.scroll_to 40, 24
      end
      game_loop do
        pass += 1
        call({ 0 => :menu, 1 => :playing }, number: :mode)
        mode = 1 if pass == 10
      end
    end
  end
end

class TestBigMaps < Minitest::Test
  include Differential
  include BigMapsGames

  RED = Color.resolve(:red)

  # A view walked across a 100x90 map, +step_x+ and +step_y+ pixels a pass, from +start+.
  private def walk(step_x, step_y, start: [0, 0], map: scrambled(100, 90))
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground, map: map
      x = var :view_x, start[0].to_f
      y = var :view_y, start[1].to_f
      game_loop do
        x += step_x.to_f
        y += step_y.to_f
        ground.scroll_to x.to_i, y.to_i
      end
    end
  end

  def test_a_map_wider_and_taller_than_64_cells_builds
    assert_backends_agree(walk(0, 0), frames: 2, name: "BIG0")
  end

  def test_the_view_shows_the_map_at_walking_pace
    prog = walk(1.25, 1.25)
    [9, 40].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGW") }
  end

  def test_the_view_shows_the_map_at_four_pixels_a_frame
    prog = walk(4, 3, start: [300, 200])
    [7, 30].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGF") }
  end

  def test_the_view_shows_the_map_walking_back
    assert_backends_agree(walk(-4, -4, start: [500, 450]), frames: 25, name: "BIGB")
  end

  # Far past the edge of the map nothing is drawn — the backdrop shows — rather than the
  # map coming round again from its other side.
  def test_past_the_edge_of_a_big_map_shows_nothing
    prog = walk(0, 0, start: [-40, -40])
    shown = game_player.run(prog, frames: 2).screen
    refute_includes [RED, Color.resolve(:green), Color.resolve(:blue), Color.resolve(:white)],
                    shown.pixel(10, 10)
    assert_backends_agree(prog, frames: 2, name: "BIGE")
  end

  # A jump far across the map shows the new place on the frame it lands.
  private def jump
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground, map: test.scrambled(120, 110)
      pass = var :pass, 0
      x = var :view_x, 0
      y = var :view_y, 0
      game_loop do
        pass += 1
        if pass == 4
          x = 700
          y = 600
        end
        ground.scroll_to x, y
      end
    end
  end

  def test_a_jump_shows_the_new_place_on_the_frame_it_lands
    [4, 5, 6].each { |frames| assert_backends_agree(jump, frames: frames, name: "BIGJ") }
  end

  # --- rooms of different sizes, and walking between them ---

  # A small room and a big one on one background. The game walks into the big room on the
  # fourth pass, with the view moved deep into it on the same pass, then walks the view
  # back toward its corner.
  private def rooms
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground,
                                   map: { hut: test.scrambled(30, 20, seed: 3), field: test.scrambled(110, 96) }
      pass = var :pass, 0
      room = var :room, 0
      x = var :view_x, 0
      y = var :view_y, 0
      game_loop do
        pass += 1
        if pass == 4
          room = 1
          x = 400
          y = 300
        end
        if pass > 4
          x -= 3
          y -= 2
        end
        ground.show_map room
        ground.scroll_to x, y
      end
    end
  end

  def test_rooms_of_different_sizes_share_one_background
    [3, 4, 5, 12].each { |frames| assert_backends_agree(rooms, frames: frames, name: "BIGR") }
  end

  # The small room is drawn at its own size: past its edge the view shows nothing, so a
  # smaller room does not cost a big one's room in the cartridge either.
  def test_a_small_room_beside_a_big_one_stops_at_its_own_edge
    refute_includes [RED, Color.resolve(:green), Color.resolve(:blue), Color.resolve(:white)],
                    game_player.run(edge_of_hut, frames: 2).screen.pixel(200, 10)
  end

  private def edge_of_hut
    test = self
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground,
                                   map: { hut: test.scrambled(20, 20, seed: 3), field: test.scrambled(110, 96) }
      game_loop { ground.scroll_to 0, 0 }
    end
  end

  # A big room in an area of its own tiles, walked into from a small room of another area.
  private def areas
    test = self
    program do
      screen :tiled
      test.tileset(self)
      image(:moss, "#" => :green, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      image(:sand, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      tiles :wilds, "r" => :moss, "g" => :sand, "b" => :b, "w" => :w
      ground = background :ground, tiles: { shrine: :ground, wilds: :wilds },
                                   map: { shrine: { hall: test.scrambled(30, 20, seed: 5) },
                                          wilds: { woods: test.scrambled(126, 126, seed: 9) } }
      pass = var :pass, 0
      room = var :room, 0
      x = var :view_x, 0
      y = var :view_y, 0
      game_loop do
        pass += 1
        if pass == 3
          room = 1
          x = 600
          y = 700
        end
        if pass > 3
          x += 4
          y += 1
        end
        ground.show_map room
        ground.scroll_to x, y
      end
    end
  end

  def test_a_big_room_of_another_area_comes_in_with_its_tiles
    [2, 3, 4, 10].each { |frames| assert_backends_agree(areas, frames: frames, name: "BIGA") }
  end

  # A scene that takes over again shows its big room from the top, filled whole. The view
  # starts +start+ pixels across and down and moves on from there each pass.
  private def scenes(start: 0)
    test = self
    program do
      screen :tiled
      test.tileset(self)
      mode = var :mode, 0
      pass = var :pass, 0
      scene(:outside) do
        ground = background :ground, tiles: :ground, map: test.scrambled(100, 90)
        x = var :view_x, start
        x += 5
        ground.scroll_to x, x
      end
      scene(:inside) { nil }
      game_loop do
        pass += 1
        mode = 1 if pass == 6
        mode = 0 if pass == 8
        call({ 0 => :outside, 1 => :inside }, number: :mode)
      end
    end
  end

  def test_a_scene_coming_back_fills_its_big_room_again
    [5, 9, 11].each { |frames| assert_backends_agree(scenes, frames: frames, name: "BIGS") }
  end

  # The frame the scene comes back on shows the room's top-left corner: a background put up
  # again is put up as declared, with its view at the corner, and the game's own place for
  # the view reaches the display in the gap after that pass. So the cells brought in as the
  # scene comes back have to be the ones round the corner, wherever the view was left. Here
  # it was left well away from it, and the frame after shows it there again — and left only a
  # few cells from it, where the cells for the game's place are then brought in a strip at a
  # time from the corner's, not all at once.
  def test_the_frame_a_scene_comes_back_shows_its_big_room_from_the_corner
    [200, 24].each do |start|
      left_away = scenes(start: start)
      [7, 8, 9, 10].each { |frames| assert_backends_agree(left_away, frames: frames, name: "BIGC") }
    end
  end

  # One name, a big room in each of two scenes: :ground is declared in both, each with a big map
  # of its own, and each scene walks its view across its own. The view brought along is the one
  # of the scene up, from its own map.
  private def big_rooms_in_two_scenes
    test = self
    program do
      screen :tiled
      test.tileset(self)
      mode = var :mode, 0
      pass = var :pass, 0
      x = var :view_x, 0
      %i[forest swamp].each_with_index do |name, seed|
        scene(name) do
          ground = background :ground, tiles: :ground, map: test.scrambled(100, 90, seed: seed + 3)
          ground.scroll_to x, x
        end
      end
      game_loop do
        pass += 1
        x += 6
        mode = 1 if pass == 6
        mode = 0 if pass == 12
        call({ 0 => :forest, 1 => :swamp }, number: :mode)
      end
    end
  end

  def test_a_name_in_two_scenes_brings_along_the_view_of_its_own_big_room
    [4, 7, 10, 13, 16].each { |frames| assert_backends_agree(big_rooms_in_two_scenes, frames: frames, name: "BIGN") }
  end

  # A scene's first takeover, named at the end of the pass before: both backends draw the same
  # room around the switch. (That its view is filled only once is measured in the cartridge's file.)
  def test_a_first_takeover_named_at_the_end_of_the_pass_before_draws_the_room
    test = self
    prog = program { test.named_at_the_end_of_a_pass(self) }
    [10, 11, 12, 13].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGF2") }
  end

  # --- walls ---

  # A wall far into the second, bigger room stops a mover there: the walls of each room are
  # read at that room's own place, whatever size the first room is. The view sits over the
  # wall so the console's picture shows where the mover stopped.
  private def wall_deep_in_a_bigger_room
    field = Array.new(100) { "." * 100 }
    field[80] = ("." * 70) + "#" + ("." * 29)
    program do
      screen :tiled
      image(:floor, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:rock, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :ground, "." => :floor, "#" => :rock, solid: ["#"]
      image(:hero_art, "#" => :red) { (["#" * 8] * 8).join("\n") }
      ground = background :ground, tiles: :ground, map: { hut: ["...."] * 4, field: field }
      ground.show_map :field
      hero = sprite :hero_art, at: [(70 * 8) - 20, 80 * 8]
      hero.blocked_by ground
      # The hero stands where the map's wall is, far off the screen, so it is hidden and this
      # stands in the screen at the same place less 500, showing where the hero stopped.
      hero.hide
      marker = sprite :hero_art, at: [0, 40]
      stood = var :stood, 0
      game_loop do
        hero.move :right, by: 2
        stood = hero.x
        marker.move_to hero.x - 500, 40
        ground.scroll_to (70 * 8) - 120, (80 * 8) - 80
      end
    end
  end

  def test_a_wall_deep_in_a_bigger_room_stops_a_mover
    assert_equal (70 * 8) - 8, game_player.run(wall_deep_in_a_bigger_room, frames: 30)[:stood]
  end

  def test_both_backends_stop_the_mover_at_that_wall
    assert_backends_agree(wall_deep_in_a_bigger_room, frames: 30, name: "BIGWL")
  end

  # --- a map that fits a grid of 64 cells, which comes round past its edges ---

  # A map of at most 64 cells each way fits a grid, and a grid comes round: past the map's right
  # edge the view shows its left one again, and above its top its bottom. A map smaller than its grid
  # shows nothing in the grid's cells past its own, then comes round at the grid's edge. That holds
  # on a console whose own grid is smaller and keeps such a map whole (the Color's is 32 cells).

  # Where the view is put, a pass each, in pixels: part off each edge, wholly off each, across the
  # grid's 32nd column and row.
  REPEAT_SPOTS = [[-40, -40], [-20, 12], [400, -30], [470, 430], [-300, 40], [100, -500], [700, 10], [512, 512],
                  [-160, -144], [255, 255], [3, 5]].freeze

  def test_a_view_part_off_a_map_of_64_cells_shows_the_map_coming_round
    assert_backends_agree(jumps_on(scrambled(64, 64)), frames: REPEAT_SPOTS.length + 2, name: "BIGR64")
  end

  def test_a_view_part_off_a_map_of_40_by_20_cells_shows_the_grid_coming_round
    assert_backends_agree(jumps_on(scrambled(40, 20)), frames: REPEAT_SPOTS.length + 2, name: "BIGR40")
  end

  def test_a_view_walked_off_a_map_of_64_cells_shows_the_map_coming_round
    prog = walk(-4, -3, start: [12, 10], map: scrambled(64, 64))
    [6, 20].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGRW") }
  end

  def test_a_view_walked_off_a_map_of_40_by_20_cells_shows_the_grid_coming_round
    prog = walk(5, 3, start: [340, 120], map: scrambled(40, 20))
    [6, 30].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGRW40") }
  end

  # A cell changed where the view shows it only by coming round: the view past the bottom right of a
  # 40 by 20 map's grid, which comes round to the map's top left, two cells there changed, and the
  # view walked on.
  def test_a_cell_changed_past_the_edge_the_view_comes_round_to_shows
    test = self
    prog = program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground, map: test.scrambled(40, 20)
      pass = var :pass, 0
      x = var :view_x, 480
      game_loop do
        pass += 1
        ground.set_tile 3, 2, "w" if pass == 4
        ground.set_tile 1, 5, "r" if pass == 5
        x += 1 if pass > 5
        ground.scroll_to x, 240
      end
    end
    [5, 7, 20].each { |frames| assert_backends_agree(prog, frames: frames, name: "BIGRS") }
  end

  # +map+, its view put at each of REPEAT_SPOTS in turn.
  private def jumps_on(map)
    test = self
    spots = REPEAT_SPOTS
    program do
      screen :tiled
      test.tileset(self)
      ground = background :ground, tiles: :ground, map: map
      pass = var :pass, 0
      game_loop do
        pass += 1
        spots.each_with_index { |(x, y), at| ground.scroll_to(x, y) if pass == at + 1 }
      end
    end
  end
end
