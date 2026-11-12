# frozen_string_literal: true

require "test_helper"

# A SCREEN OF TILES ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun): the picture
# the player is shown, built by the processor from the maps (Runtime::Scenery). What a background does is in
# test/all/vblank/builder/test_tiled_background.rb and its neighbours, which this run plays; these are what is
# DOS's own: a grid narrower than the 320 pixels across, so the map comes round on the screen; tiles with
# some, all and none of their pixels see-through, laid four at a time; a map too big for a grid, scrolled
# past every edge; and a scrolled view built in less than a frame.
class TestDOSScenery < Minitest::Test
  DOS = VBlank::IR::Backends::DOS

  # Eight by eight: one colour all over, one with a see-through checker, one see-through all over.
  SOLID = ("########\n" * 8).freeze
  CHECKER = ("#.#.#.#.\n.#.#.#.#\n" * 4).freeze
  NOTHING = ("........\n" * 8).freeze

  private def program_of(&game) = VBlank.game("DOSGAME", consoles: %i[dos], &game).program(console: :dos)
  private def checked(frames:, &game) = DOS::CheckedRun.new.run(program_of(&game), frames: frames)

  # Each column's own tile, so a map that comes round a column too early or too late shows. Public, as the
  # games call back through it.
  def stripes(cols, rows) = Array.new(rows) { |r| Array.new(cols) { |c| "RGBW"[(c + r) % 4] }.join }

  # The tiles every game here draws with. Public, as the games call back through it.
  def tilesets(game)
    game.instance_eval do
      image(:red, "#" => :red) { SOLID }
      image(:green, "#" => :green) { SOLID }
      image(:blue, "#" => :blue) { SOLID }
      image(:white, "#" => :white) { SOLID }
      image(:checker, "#" => :yellow, "." => :transparent) { CHECKER }
      image(:nothing, "." => :transparent) { NOTHING }
      tiles :colors, "R" => :red, "G" => :green, "B" => :blue, "W" => :white
      tiles :over, "C" => :checker, "N" => :nothing
    end
  end

  # A map of 30 columns has a grid of 32, 256 pixels, so the screen's last 64 show it again: put up from its
  # corner, and then scrolled each way, the window brought round at the grid's edge.
  def test_a_map_comes_round_across_a_screen_wider_than_its_grid
    test = self
    checked(frames: 12) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(30, 20)
      step = var :step, 0
      game_loop do
        step += 1
        field.scroll_to step * 37 - 200, 300 - step * 29 if step > 2
      end
    end
  end

  # Tiles of every kind over a background of solid ones, both scrolled their own ways: a checker laid with its
  # mask, starting part way into a tile at either edge of the screen, and a tile with nothing to lay.
  def test_tiles_with_see_through_pixels_over_another_background
    test = self
    checked(frames: 10) do
      screen :tiled, backdrop: :blue
      test.tilesets(self)
      back = background :back, tiles: :colors, map: test.stripes(32, 32)
      front = background :front, tiles: :over, map: Array.new(32) { |r| (r.even? ? "CN" : "NC") * 16 }
      step = var :step, 0
      game_loop do
        step += 1
        back.scroll_to step * 3, step
        front.scroll_to 0 - step * 5, step * 2 + 1
      end
    end
  end

  # A map bigger than any grid is shown once: left of it, above it, right of it and below it shows the backdrop.
  def test_a_map_too_big_for_a_grid_shows_the_backdrop_past_every_edge
    test = self
    checked(frames: 8) do
      screen :tiled, backdrop: :white
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(70, 20)
      places = [[-30, -20], [400, 50], [250, -150], [-600, 100], [0, 0], [2_147_483_000, 10]]
      step = var :step, 0
      game_loop do
        places.each_with_index { |(x, y), i| field.scroll_to x, y if step == i }
        step += 1
      end
    end
  end

  # What the game paints over the scenery is painted over again by the next view the interpreter builds, even
  # one showing the scenery from where it showed it before.
  def test_painting_over_the_scenery_goes_at_the_next_view
    test = self
    checked(frames: 6) do
      screen :tiled
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(32, 32)
      step = var :step, 0
      game_loop do
        step += 1
        field.scroll_to 8, 0
        fill_rect 10, 10, 20, 20, :red if step == 3
      end
    end
  end

  # The furthest left a scroll can be, -2^31, over a map too big for a grid, shows nothing of the map.
  def test_the_furthest_left_scroll_shows_nothing_of_a_big_map
    test = self
    run = checked(frames: 2) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(70, 20)
      game_loop { field.scroll_to(-2_147_483_647 - 1, 0) }
    end

    assert_equal VBlank::Graphics::Color.resolve(:black), run.screen.pixel(0, 0)
  end

  # A background in a named layer can be put up behind one already up, and the stack is settled again then,
  # which is not made yet: such a game is refused by name.
  def test_a_background_in_a_named_layer_is_refused
    test = self
    error = assert_raises(DOS::Lowering::NotMadeYet) do
      DOS.new.build(program_of do
        screen :tiled
        test.tilesets(self)
        layers :sky, :world
        layer(:world) { background :front, tiles: :over, map: Array.new(4, "CN" * 4) }
        layer(:sky) { background :back, tiles: :colors, map: test.stripes(8, 4) }
        game_loop {}
      end)
    end

    assert_match(/named layer/, error.message)
  end

  # One background scrolled every pass is built again every pass, and in less than a frame, so the game's
  # passes keep to the screen's frames on either screen.
  def test_a_scrolled_view_is_built_within_a_frame
    test = self
    run = checked(frames: 8) do
      screen :tiled
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(32, 32)
      passes = var :passes, 0
      frames = var :frames, 0
      game_loop do
        field.scroll_by 3, 1
        passes += 1
        frames = frames_since_power_on
      end
    end

    assert_equal run[:passes], run[:frames], "every pass took one frame"
  end
end
