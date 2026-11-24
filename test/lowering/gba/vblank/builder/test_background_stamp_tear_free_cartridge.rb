# frozen_string_literal: true

require "test_helper"
require "differential"

# A background on a painted screen is stamped tile by tile, and a tile's black pixels are the
# ones the screen under it shows through (Image#tile_see_through_at?). On the tear-free screen the
# cartridge must leave what is under those pixels alone, as the interpreter does.
class TestBackgroundStampTearFreeCartridge < Minitest::Test
  include Differential

  # Red over the whole screen, then a map of one tile stamped on it. +art+ is the tile's rows.
  private def stamped(art, cells: 4)
    VBlank.game("STAMP", consoles: %i[gba]) do
      screen :bitmap, tear_free: true
      image(:tile, "#" => :white, "." => :black) { art }
      tiles :set, "t" => :tile
      game_loop do
        clear_screen :red
        background :bg, tiles: :set, map: Array.new(cells) { "t" * cells }
      end
    end.program
  end

  def test_black_pixels_of_a_tile_show_what_is_under_them
    checker = Array.new(8) { |row| row.even? ? "#.#.#.#." : ".#.#.#.#" }.join("\n")
    assert_backends_agree(stamped(checker), frames: 6, name: "STAMPCHK")
  end

  # A pixel on its own in a pair of pixels is written by itself, on either side of the pair.
  def test_a_tile_with_two_lone_pixels_leaves_the_rest_alone
    dots = (["........"] * 8).each_with_index.map { |row, at| at == 2 ? "...#...." : row }.tap { |rows| rows[0] = "#......." }.join("\n")
    assert_backends_agree(stamped(dots), frames: 6, name: "STAMPDOT")
  end

  def test_a_tile_with_no_black_in_it_still_covers_what_is_under_it
    solid = (["########"] * 8).join("\n")
    assert_backends_agree(stamped(solid), frames: 6, name: "STAMPSOL")
  end

  # Cells past the edge of the screen are cut off, as a tile hanging off an edge is.
  def test_tiles_hanging_off_the_screen_are_cut_off
    checker = Array.new(8) { |row| row.even? ? "#.#.#.#." : ".#.#.#.#" }.join("\n")
    assert_backends_agree(stamped(checker, cells: 32), frames: 6, name: "STAMPOFF")
  end
end
