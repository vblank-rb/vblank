# frozen_string_literal: true

require "test_helper"

# A GROUP OF TILE PICTURES IN ALL FOUR COLOURS OF A COLOR PALETTE. Its list is see-through first,
# never drawn, and four solid after, none of them the backdrop. The first of the four shows, not
# the backdrop, and the group fades through a list of its own beside tiles of another.
class TestTilePicturesOfFourSolidColors < Minitest::Test
  private def field
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled, backdrop: :black
      colors :field, %i[transparent white red green blue]
      colors :board, %i[transparent yellow orange cyan white]
      colors :board_dim, %i[transparent red green blue black]
      image :plain, width: 8, height: 8, colors: :field, places: Array.new(64) { |at| (at % 4) + 1 }
      image :first, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| (at % 4) + 1 }
      image :second, width: 8, height: 8, colors: :board, places: Array.new(64) { |at| ((at + 1) % 4) + 1 }
      group = tile_pictures :billboard, tiles: { a: %i[first second] }, colors: :board
      tiles :set, "." => :plain, "a" => group[:a]
      ground = background :ground, tiles: :set, map: ["..a."]
      pass = var :pass, 0
      game_loop do
        pass += 1
        group.show(pass / 8 % 2)
        ground.draw_with({ board: :board_dim }) if pass == 12
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_group_shows_its_four_colours_and_fades_as_the_interpreter_shows_them
    game_player.run(field, frames: 24)
    pass
  end
end
