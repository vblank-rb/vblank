# frozen_string_literal: true

require "test_helper"

# A SCREEN OF TILES ON A PC, in DOSBox, held to the interpreter on every pass (DOS::CheckedRun): the picture
# the player is shown, built by the processor from the maps (Runtime::Scenery). What a background does is in
# test/all/vblank/builder/test_tiled_background.rb and its neighbours, which this run plays; these are what is
# DOS's own: a grid narrower than the 320 pixels across, so the map comes round on the screen; tiles with
# some, all and none of their pixels see-through, laid four at a time; a map too big for a grid, scrolled
# past every edge; a scrolled view built in less than a frame; cells changed at and past every edge of the
# map, and more held at once than wait together; maps of different sizes; tiles painted from a list
# that holds fewer bytes than they take; and backgrounds in blocks, one that turns and one see-through, and
# one built in less than a frame in small blocks.
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

  # Backgrounds in named layers put up in another order than the stack draws them: the one behind, stamped over
  # the picture as it goes up, would cover the one in front, where the interpreter keeps it behind.
  def test_a_background_put_up_behind_one_already_up_stays_behind
    test = self
    run = checked(frames: 3) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      layers :sky, :world
      layer(:world) { background :front, tiles: :over, map: Array.new(4, "CN" * 4) }
      layer(:sky) { background :back, tiles: :colors, map: test.stripes(8, 4) }
      game_loop {}
    end

    assert_equal VBlank::Graphics::Color.resolve(:yellow), run.screen.pixel(0, 0)
  end

  # A background put up while another is shown alone above its row is built into the view, below that row, and
  # never stamped over the rows the other has alone (Reference#stamp_background).
  def test_a_background_put_up_under_one_shown_alone_stays_below_its_row
    test = self
    run = checked(frames: 3) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      background :top, tiles: :over, map: Array.new(4, "CN" * 4), above_row: 16, alone: true
      background :field, tiles: :colors, map: test.stripes(40, 25)
      game_loop {}
    end

    assert_equal VBlank::Graphics::Color.resolve(:black), run.screen.pixel(1, 0), "a see-through pixel of the top shows the backdrop"
  end

  # A background held above a row that turns is drawn on every row, as the interpreter draws a turned background
  # (Reference#paint_affine_background_window reads the rows the backgrounds are seen in, not its own row).
  def test_a_turned_background_held_above_a_row_is_drawn_on_every_row
    test = self
    checked(frames: 3) do
      screen :rotozoom, backdrop: :black
      test.tilesets(self)
      background :under, tiles: :colors, map: test.stripes(20, 20)
      top = background :top, tiles: :colors, map: test.stripes(32, 8), above_row: 40
      game_loop { top.rotate 20 }
    end
  end

  # A screen that turns is another kind than one of tiles (SceneHandover::DISPLAYS): moving to it and back wipes the
  # display, and what every screen shows comes back as declared, the cell changed before gone.
  def test_a_turning_screen_and_back_puts_the_scenery_up_again_as_declared
    test = self
    checked(frames: 10) do
      screen :tiled
      test.tilesets(self)
      floor = background :floor, tiles: :colors, map: test.stripes(32, 32)
      state = var :state, 0
      tick = var :tick, 0
      scene(:one) { floor.set_tile 0, 0, "W" if tick == 2 }
      scene(:two) { screen :rotozoom }
      game_loop do
        tick += 1
        state = 1 if tick == 5
        state = 0 if tick == 8
        case_var(:state) do
          when_val 0, :one
          when_val 1, :two
        end
      end
    end
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
  # A SCREEN OF TILES IN BLOCKS (Runtime::Scenery#emit_blocked_window): a background that turns is a single
  # pixel wide at blocks of two and in blocks both ways from three, and one with see-through tiles over another is
  # laid with its mask, each in blocks by itself; the sizes change pass by pass from one to the biggest and past it.
  def test_a_turning_background_and_one_see_through_in_blocks_of_every_size
    test = self
    checked(frames: 22) do
      screen :rotozoom, backdrop: :black
      test.tilesets(self)
      background :under, tiles: :colors, map: test.stripes(20, 20)
      top = background :top, tiles: :over, map: Array.new(16) { |r| (r.even? ? "CN" : "NC") * 8 }
      size = var :size, 0
      angle = var :angle, 0
      game_loop do
        size += 1
        angle += 7
        top.rotate angle
        pixelate size
      end
    end
  end

  # The smaller the blocks the more work: a row of blocks drawn and spread for each row of them. A background in them
  # scrolled every pass is still built in less than a frame, so the game's passes keep to the screen's frames, as a
  # fade timed in frames needs them to. The budget is the one background drawn as it is
  # (#test_a_scrolled_view_is_built_within_a_frame), at the smallest blocks that keep to it, measured on 2026-11-17:
  # blocks of two on the plain screen (320 x 200, 70 frames a second), and of three on Mode X (320 x 240, 60 a
  # second), where blocks of two take two frames a pass. Two backgrounds scrolled every pass take two frames a pass
  # with or without blocks. Both are the speed work still to do.
  def test_a_scrolled_view_in_the_smallest_blocks_that_keep_to_a_frame
    test = self
    smallest = described_game_console.screen_height > 200 ? 3 : 2
    run = checked(frames: 8) do
      screen :tiled
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(32, 32)
      passes = var :passes, 0
      frames = var :frames, 0
      game_loop do
        pixelate smallest
        field.scroll_by 3, 1
        passes += 1
        frames = frames_since_power_on
      end
    end

    assert_equal run[:passes], run[:frames], "every pass took one frame"
  end

  # Cells changed past the map's right edge and below its last row, inside the grid it is kept in, at numbers
  # below nought and too big for a word, to a tile they already have, and from a list of keys by a number that
  # names a key, an empty cell or none.
  def test_cells_change_only_inside_the_map
    test = self
    checked(frames: 12) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(30, 18)
      step = var :step, 0
      game_loop do
        step += 1
        field.scroll_to step * 5, 0
        field.set_tile step + 26, 3, "W"
        field.set_tile step, 17 + (step % 3), "B"
        field.set_tile 0 - step, 2, "B"
        field.set_tile 70_000 * step, 70_000, "B"
        field.set_tile 2, 2, "R"
        field.set_tile_picked step, 5, step, [nil, "G", "B"], from: 2
      end
    end
  end

  # More changes held in one pass than wait at once: the first ones go in when the next would not fit, and the
  # rest at the frame's end, in the order they were made.
  def test_more_held_changes_than_wait_at_once
    test = self
    checked(frames: 6) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      field = background :field, tiles: :colors, map: test.stripes(32, 32), held: true
      step = var :step, 0
      game_loop do
        step += 1
        repeat(1100) do |i|
          field.set_tile_picked (i + step) % 40, i / 40, (step + i) % 2, %w[B R]
        end
      end
    end
  end

  # Maps of different sizes, kept as big as the biggest, shown by a number that names one and by numbers that
  # name none, and scrolled so the cells past the smaller one's edges show.
  def test_maps_of_different_sizes_shown_by_any_number
    test = self
    checked(frames: 12) do
      screen :tiled, backdrop: :black
      test.tilesets(self)
      short = test.stripes(32, 32).map { |row| row[0, 10] }
      field = background :field, tiles: :colors, map: { long: test.stripes(32, 32), short: short }
      step = var :step, 0
      which = var :which, 0
      game_loop do
        step += 1
        which = (step % 5) - 2
        field.show_map which
        field.scroll_to step * 7, step * 3
      end
    end
  end
  # Tiles painted from a list of bytes that holds fewer than the tiles take, and grows: a byte past its last
  # item read as nought, a place past the run's colours drawn black. Painted over and over, scrolled.
  def test_tiles_painted_from_a_list_shorter_than_them
    checked(frames: 10) do
      screen :tiled, backdrop: :blue
      colors :ink, %i[transparent white red green]
      canvas = list :canvas, capacity: 96, width: :byte
      repeat(60) { |i| canvas.push i * 37 }
      box = tiles :box, from: canvas, count: 3, colors: :ink
      field = background :field, tiles: :box, map: Array.new(4) { [1, 2, 3, 1, 2] }
      step = var :step, 0
      game_loop do
        step += 1
        canvas.push step * 91 + 0x1F0
        canvas[step] = step * 13
        box.changed
        field.scroll_to 0 - step, step
      end
    end
  end
end
