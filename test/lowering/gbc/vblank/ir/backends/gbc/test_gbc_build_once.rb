# frozen_string_literal: true

require "test_helper"
require "build_once_tests"

# What a Color build does once (BuildOnceTests), and that the art a routine made and then taken back
# adds is the art it adds again: the Color keeps a picture's tiles and palettes when a routine too
# big for a bank is put back (Lowering::LOWERING_STATE shares Art), so adding a picture twice must
# change nothing.
class TestGBCBuildOnce < Minitest::Test
  include BuildOnceTests

  runs_on_the_main_ractor! # BuildOnceTests counts calls by prepending to the lowering's classes

  BACKEND = VBlank::IR::Backends::GBC
  CONSOLE = :gbc

  RED = 0x001F
  BLUE = 0x7C00

  def test_a_picture_added_twice_takes_its_tiles_and_palette_once
    art = BACKEND::Art.new
    image = tile_picture
    first = art.background_tile(:wall, image)
    tiles = art.background_tiles.compact.length
    palettes = art.background_palettes.length

    assert_equal first, art.background_tile(:wall, image)
    assert_equal [tiles, palettes], [art.background_tiles.compact.length, art.background_palettes.length]
  end

  def test_a_sprite_picture_added_twice_takes_its_tiles_once
    art = BACKEND::Art.new
    image = tile_picture
    first = art.sprite_picture(:ball, image)
    tiles = art.sprite_tiles.compact.length

    assert_equal first, art.sprite_picture(:ball, image)
    assert_equal tiles, art.sprite_tiles.compact.length
  end

  # An 8×8 picture, red over its upper half and blue over its lower.
  private def tile_picture
    pixels = (Array.new(32, RED) + Array.new(32, BLUE)).pack("v*")
    VBlank::IR::Assets::Image.new(width: 8, height: 8, transparent: nil, pixels: pixels, colors: [0, RED, BLUE], places: nil)
  end
end
