# frozen_string_literal: true

require "test_helper"

# A TILE'S LIST OF FIVE, ONE THE BACKDROP. A Color tile holds three colours and the backdrop, and an
# ordinary tile drawn from [:transparent, backdrop, a, b, c] fits by leaving the backdrop out. A group
# of tile pictures is written from the same list without it, drawing see-through where the list
# says the backdrop: the same picture, and both fade through lists of their own in step.
class TestTilePicturesBesideBackdropTiles < Minitest::Test
  private def field
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      colors :field, %i[transparent black red green blue]
      colors :field_dim, %i[transparent black orange yellow cyan]
      colors :board, %i[transparent red green blue]
      colors :board_dim, %i[transparent orange yellow cyan]
      image :plain, width: 8, height: 8, colors: :field, places: Array.new(64) { |at| (at % 4) + 1 }
      image :first, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| at % 4 }
      image :second, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| (at + 1) % 4 }
      group = tile_pictures :billboard, tiles: { a: %i[first second] }, colors: :board
      tiles :set, "." => :plain, "a" => group[:a]
      ground = background :ground, tiles: :set, map: ["..a."]
      pass = var :pass, 0
      game_loop do
        pass += 1
        group.show(pass / 8 % 2)
        ground.draw_with({ field: :field_dim, board: :board_dim }) if pass == 12
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_group_and_the_tiles_beside_it_share_what_the_color_holds
    game_player.run(field, frames: 20)
    pass
  end
end
