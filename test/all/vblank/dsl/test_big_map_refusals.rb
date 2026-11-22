# frozen_string_literal: true

require "test_helper"

# What a background with a map bigger than the console's grid cannot do. Such a background
# holds only the cells around the view and copies them in again as the view moves (see
# IR::TileMap.streams?), so changing a block of cells at once, turning the layer, or bending its
# rows would each reach cells that are not there. One cell is changed with set_tile
# (test/all/vblank/dsl/test_background_room_cells.rb).
class TestBigMapRefusals < Minitest::Test
  private def program(&block)
    b = Builder.new
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  def big_ground(builder)
    builder.instance_eval do
      screen :tiled
      image(:floor, "#" => :green) { (["#" * 8] * 8).join("\n") }
      tiles :ground, "." => :floor
    end
  end

  def test_a_block_of_cells_of_a_big_map_cannot_be_filled
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        ground = background :ground, tiles: :ground, map: ["." * 80] * 20
        game_loop { ground.fill_tiles 1, 1, 2, 2, "." }
      end
    end
    assert_includes error.message, "fill_tiles cannot change a block"
    assert_includes error.message, "set_tile"
  end

  def test_a_big_map_cannot_turn
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        background(:ground, tiles: :ground, map: ["." * 80] * 80).rotate!(10)
        game_loop {}
      end
    end
    assert_includes error.message, "must hold its whole map at once"
  end

  def test_the_rows_of_a_big_map_cannot_bend
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        ground = background :ground, tiles: :ground, map: ["." * 80] * 20
        ground.scroll_each_row { |row| row & 3 }
        game_loop {}
      end
    end
    assert_includes error.message, "a bent row can show cells outside them"
  end

  def test_maps_of_different_sizes_cannot_bend_either
    test = self
    error = assert_raises(ArgumentError) do
      program do
        test.big_ground(self)
        ground = background :ground, tiles: :ground, map: { hut: ["...."] * 4, hall: ["......"] * 6 }
        ground.scroll_each_row { |row| row & 3 }
        game_loop {}
      end
    end
    assert_includes error.message, "not all one size"
  end
end
