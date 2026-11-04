# frozen_string_literal: true

require "test_helper"

class TestSNESArt < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  RED = 0x001F
  BLUE = 0x7C00

  # The same picture drawn from a palette whose colours sit in other places is other bytes, and a
  # build's tries share what they read of their pictures (Art::TileMemo). So a try whose palette
  # came out the other way round must not be handed the bytes an earlier try made.
  def test_a_picture_in_a_palette_of_other_places_makes_its_own_tile
    red_over_blue = picture(RED, BLUE)
    blue_over_red = picture(BLUE, RED)
    memo = SNES::Art::TileMemo.new

    first_try = SNES::Art.new(tile_memo: memo)
    red_first = tile_of(first_try, red_over_blue)

    second_try = SNES::Art.new(tile_memo: memo)
    tile_of(second_try, blue_over_red) # its palette now holds blue before red
    blue_first = tile_of(second_try, red_over_blue)

    alone = SNES::Art.new
    tile_of(alone, blue_over_red)

    refute_equal red_first, blue_first
    assert_equal tile_of(alone, red_over_blue), blue_first
  end

  # An 8×8 picture, +top+ over its upper half and +bottom+ over its lower.
  private def picture(top, bottom)
    pixels = (Array.new(32, top) + Array.new(32, bottom)).pack("v*")
    VBlank::IR::Assets::Image.new(width: 8, height: 8, transparent: nil, pixels: pixels, colors: [0, top, bottom], places: nil)
  end

  # The 32 bytes of the tile +image+ makes as a background cell of +art+.
  private def tile_of(art, image)
    number, = art.background_cell(image)
    art.background_tiles.fetch(number)
  end
end
