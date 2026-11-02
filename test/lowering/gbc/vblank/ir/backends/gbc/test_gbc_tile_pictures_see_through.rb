# frozen_string_literal: true

require "test_helper"

# A Color tile cannot show four solid colours and see-through as well, so a group of tile pictures
# with a list of five whose picture draws see-through has no way to be held.
class TestGBCTilePicturesSeeThrough < Minitest::Test
  private def see_through_picture
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :board, %i[transparent yellow orange cyan white]
      image :holed, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| at % 5 }
      group = tile_pictures :billboard, tiles: { a: %i[holed] }, colors: :board
      tiles :set, "a" => group[:a]
      background :ground, tiles: :set, map: ["a"]
      game_loop {}
    end
    b.finalize_program
    b.program
  end

  def test_a_picture_that_draws_see_through_is_refused_in_plain_words
    error = assert_raises(VBlank::BuildError) { VBlank::IR::Backends::GBC.new.build(see_through_picture, title: "HOLED") }

    assert_match(/see-through/, error.message)
  end
end
