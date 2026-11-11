# frozen_string_literal: true

require "test_helper"
require "pack_turning_background_games"

# A BACKGROUND THAT TURNS AND RESIZES, DRAWN FROM THE DATA PACK: a map of one byte a cell over
# tiles of a byte a pixel in a table of 256 colours, as a console keeps the layer it turns
# (PackTurningBackgroundGames). It is the background a game makes from pictures it draws itself,
# with its tiles, map and colours from the pack, so the answer key is that game: the same
# pixels, declared two ways, at its own size, resized about a point, and turned.
#
# A Game Boy Color cannot turn a background, so these play on the Advance's runs alone.
class TestPackTurningBackgroundsOnTheAdvance < Minitest::Test
  include PackTurningBackgroundGames

  # The layer from the pack and the layer the game draws itself show one picture after each of
  # +frames+, whatever +more+ does with the handle. Hands back the pictures, by frame.
  private def assert_shows_as_the_drawn_one(what, frames: [2, 4], **how, &more)
    Dir.mktmpdir do |folder|
      from_pack = turning_pack_game(turning_original(folder), **how, &more)
      drawn = turning_drawn_game(&more)

      frames.to_h do |count|
        shown = game_player.run(drawn, frames: count).screen
        assert_equal shown.to_a, game_player.run(from_pack, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the layer from the pack shows what the drawn one shows"
        [count, shown]
      end
    end
  end

  # Not turned at all, it is a background like any other: each pixel the colour the made-up
  # data says, a byte of the map picking the tile and a byte of the tile picking the colour.
  def test_at_its_own_size_each_pixel_is_the_tables_color_for_its_tiles_byte
    Dir.mktmpdir do |folder|
      screen = game_player.run(turning_pack_game(turning_original(folder)) { |_layer| game_loop { wait_vblank } }, frames: 3).screen
      behind = screen.pixel(0, 0) # the map's first cell is tile 0, which draws nothing
      checked = [[9, 3], [20, 5], [43, 17], [100, 60], [181, 88], [224, 152], [66, 131]]

      checked.each do |x, y|
        assert_equal turning_map_color(x, y) || behind, screen.pixel(x, y), "the pixel at (#{x}, #{y})"
      end
      assert_operator checked.count { |x, y| turning_map_color(x, y) }, :>=, 4, "most of the pixels checked are drawn"
    end
  end

  def test_at_its_own_size_it_shows_as_the_same_background_drawn_by_the_game
    assert_shows_as_the_drawn_one("at its own size") { |_layer| game_loop { wait_vblank } }
  end

  # Never turned, it scrolls as any background does.
  def test_never_turned_it_scrolls_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("scrolled", frames: [2, 6]) do |layer|
      game_loop do
        wait_vblank
        layer.scroll_by 3, 1
      end
    end

    refute_equal pictures.fetch(2).to_a, pictures.fetch(6).to_a
  end

  def test_made_to_turn_and_left_upright_it_shows_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("upright") do |layer|
      layer.rotate(0)
      game_loop { wait_vblank }
    end

    assert_equal TABLE.fetch(BYTE_TILES[3][0]), pictures.fetch(4).pixel(8, 0), "the map's second cell is tile 3"
  end

  def test_scaled_up_about_a_point_it_shows_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("twice the size") do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
      game_loop { wait_vblank }
    end

    # The map's middle is at the pivot, and each of its pixels is two of the screen's.
    assert_equal turning_map_color(*MIDDLE), pictures.fetch(4).pixel(*PIVOT)
    assert_equal turning_map_color(MIDDLE[0] + 16, MIDDLE[1] + 3), pictures.fetch(4).pixel(PIVOT[0] + 32, PIVOT[1] + 6)
  end

  def test_scaled_down_about_a_point_it_shows_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("half the size") do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(0.5)
      game_loop { wait_vblank }
    end

    assert_equal turning_map_color(MIDDLE[0] + 16, MIDDLE[1]), pictures.fetch(4).pixel(PIVOT[0] + 8, PIVOT[1])
  end

  def test_turned_about_a_point_it_shows_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("turned") do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).rotate(90)
      game_loop { wait_vblank }
    end

    # A quarter clockwise: the screen's pixel below the pivot is the map's pixel right of its middle.
    assert_equal turning_map_color(MIDDLE[0] + 21, MIDDLE[1]), pictures.fetch(4).pixel(PIVOT[0], PIVOT[1] + 21)
  end

  # A size the game eases and an angle it turns, a frame at a time.
  def test_resized_and_turned_as_the_game_runs_it_shows_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("easing", frames: [2, 3, 5, 8, 12]) do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(4.0)
      spin = var :spin, 0
      game_loop do
        layer.scale.approach! 1.0, 0.25
        spin += 7
        layer.rotate spin
      end
    end

    assert_operator pictures.values.map(&:to_a).uniq.length, :>=, 4, "the layer moves from frame to frame"
  end

  # Shown and hidden as the game says: nowhere for its first frames, then everywhere.
  def test_hidden_and_then_shown_it_shows_as_the_drawn_one
    pictures = assert_shows_as_the_drawn_one("hidden, then shown", frames: [3, 9]) do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
      layer.show_only_inside(0, 0, 0, 0)
      pass = var :pass, 0
      game_loop do
        pass += 1
        layer.show_everywhere if pass == 5
      end
    end

    assert_equal 1, pictures.fetch(3).to_a.flatten.uniq.length, "hidden, the screen is what is behind the layer"
    assert_operator pictures.fetch(9).to_a.flatten.uniq.length, :>, 4, "shown, it is the layer"
  end

  # WITH THE PACK LEFT OUT (`pack_at_start: true`) the program holds none of the map, the tiles or
  # the table, and reads them from the file it is handed as it starts. Only a build for a
  # computer leaves its pack out, so these are played by the interpreter and by the game as C,
  # JavaScript and Ruby built for the Advance. The answer key is still the background the game
  # draws itself, which holds its pictures and is handed no file.
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  private def assert_read_at_start_shows_as_the_drawn_one(what, frames: [2, 4], **how, &more)
    Dir.mktmpdir do |folder|
      from = turning_original(folder)
      _whole, file = turning_pack_game_and_file(from, **how, &more)
      left_out, = turning_pack_game_and_file(from, options: LEFT_OUT, **how, &more)
      drawn = turning_drawn_game(&more)

      frames.to_h do |count|
        shown = game_player.run(drawn, frames: count).screen
        assert_operator shown.to_a.flatten.uniq.length, :>, 4, "#{what}: the drawn one shows the layer"
        assert_equal shown.to_a, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the layer read as the game starts shows what the drawn one shows"
        [count, shown]
      end
    end
  end

  def test_read_at_start_at_its_own_size_it_shows_as_the_drawn_one
    assert_read_at_start_shows_as_the_drawn_one("at its own size") { |_layer| game_loop { wait_vblank } }
  end

  def test_read_at_start_scaled_up_about_a_point_it_shows_as_the_drawn_one
    assert_read_at_start_shows_as_the_drawn_one("twice the size") do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
      game_loop { wait_vblank }
    end
  end

  def test_read_at_start_scaled_down_about_a_point_it_shows_as_the_drawn_one
    assert_read_at_start_shows_as_the_drawn_one("half the size") do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(0.5)
      game_loop { wait_vblank }
    end
  end

  def test_read_at_start_resized_and_turned_as_the_game_runs_it_shows_as_the_drawn_one
    assert_read_at_start_shows_as_the_drawn_one("easing", frames: [2, 3, 5, 8, 12]) do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(4.0)
      spin = var :spin, 0
      game_loop do
        layer.scale.approach! 1.0, 0.25
        spin += 7
        layer.rotate spin
      end
    end
  end

  def test_read_at_start_hidden_and_then_shown_it_shows_as_the_drawn_one
    Dir.mktmpdir do |folder|
      from = turning_original(folder)
      game = lambda do |layer|
        layer.turns_around(*PIVOT, map_point: MIDDLE).scale(2.0)
        layer.show_only_inside(0, 0, 0, 0)
        pass = var :pass, 0
        game_loop do
          pass += 1
          layer.show_everywhere if pass == 5
        end
      end
      _whole, file = turning_pack_game_and_file(from, &game)
      left_out, = turning_pack_game_and_file(from, options: LEFT_OUT, &game)
      drawn = turning_drawn_game(&game)

      [3, 9].each do |count|
        assert_equal game_player.run(drawn, frames: count).screen.to_a,
                     game_player.hand_file(file).run(left_out, frames: count).screen.to_a, "after #{count} frames"
      end
    end
  end

  def test_read_at_start_a_map_that_is_a_run_of_a_slot_over_tiles_from_a_tile_on_shows_as_the_drawn_one
    assert_read_at_start_shows_as_the_drawn_one("from runs", from_runs: true) do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).rotate(30)
      game_loop { wait_vblank }
    end
  end

  # The map as a run of a bigger slot, and the tiles from a tile of their slot on.
  def test_a_map_that_is_a_run_of_a_slot_over_tiles_from_a_tile_on_shows_as_the_drawn_one
    assert_shows_as_the_drawn_one("from runs", from_runs: true) do |layer|
      layer.turns_around(*PIVOT, map_point: MIDDLE).scale(1.5)
      game_loop { wait_vblank }
    end
  end
end
