# frozen_string_literal: true

require "test_helper"
require "pack_cells_in_front_tests"

# `cells_in_front:` asked of a background that cannot read the mark (Builder::PackBackgrounds
# #front_read_format!, #refuse_bad_cells_in_front!), refused the same on every console. What the
# setting draws is played by each console that draws it, test/pack_cells_in_front_tests.rb.
class TestPackCellsInFront < Minitest::Test
  include PackCellsInFrontGames

  def test_cells_in_front_given_something_but_true_or_false_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { front_game(folder, cells_in_front: :yes) }

      assert_includes error.message, "cells_in_front: :yes"
      assert_includes error.message, "true"
    end
  end

  # The Advance's own cell keeps its tile, its turns and its bank, and no priority.
  def test_cells_in_front_of_a_map_in_the_advances_own_layout_is_refused
    Dir.mktmpdir do |folder|
      words = [ADVANCE_CELL.(1), ADVANCE_CELL.(2)]
      from = original(folder, :gba, advance_tiles, words)
      b = VBlank::Builder.new
      error = assert_raises(ArgumentError) do
        b.instance_eval do
          screen :tiled
          pack = data_pack from: from, version: "1" do |slots|
            slots.tiles :video, at: TILES_AT, count: 4
            slots.numbers :map, at: MAP_AT, count: words.length, width: :half, signed: false
            slots.colors :palette, at: COLORS_AT, count: 32
          end
          background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: 2, cells_in_front: true
        end
      end

      assert_includes error.message, "no mark"
      assert_includes error.message, "in_front: true"
    end
  end

  def test_cells_in_front_on_a_background_not_from_the_pack_is_refused
    b = VBlank::Builder.new
    error = assert_raises(ArgumentError) do
      b.instance_eval do
        screen :tiled
        image(:sea, "." => :blue) { "........\n" * 8 }
        tiles :set, "." => :sea
        background :field, tiles: :set, map: ["."], cells_in_front: true
      end
    end

    assert_includes error.message, "cells_in_front:"
  end

  # --- a sprite in front (`in_front: true`), refused alike on every console ---

  def test_in_front_given_something_but_true_or_false_is_refused
    error = assert_raises(ArgumentError) { sprites_game { sprite :pointer, at: [0, 0], in_front: :yes } }

    assert_includes error.message, ":pointer"
    assert_includes error.message, "true or false"
  end

  def test_a_sprite_in_front_in_a_layer_is_refused
    error = assert_raises(ArgumentError) do
      sprites_game do
        layers :back, :front
        layer(:back) { sprite :pointer, at: [0, 0], in_front: true }
      end
    end

    assert_includes error.message, ":back"
  end

  def test_a_sprite_in_front_in_a_draw_order_is_refused
    error = assert_raises(ArgumentError) do
      sprites_game do
        pointer = sprite :pointer, at: [0, 0], in_front: true
        walker = sprite :walker, at: [0, 0]
        draw_in_order pointer, walker
      end
    end

    assert_includes error.message, "in_front: true"
  end

  private def sprites_game(&more)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      image(:pointer, "#" => :red) { "########\n" * 8 }
      image(:walker, "#" => :blue) { "########\n" * 8 }
      instance_eval(&more)
    end
    b.finalize_program
    b.program
  end
end
