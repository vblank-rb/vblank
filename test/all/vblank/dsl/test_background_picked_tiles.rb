# frozen_string_literal: true

require "test_helper"

# A tile given to a cell by a number the game works out: numbers past either end of the tileset, and a
# cell off the map, leave the cell as it was, on a background that writes at once and on one that holds
# its changes for the gap between frames. Each console's build is held to the interpreter on every pass.
class TestBackgroundPickedTiles < Minitest::Test
  private def game(held:)
    VBlank.game("PICKED", consoles: %i[gba gbc snes genesis ps1]) do
      screen :tiled
      images = (0...6).to_h do |n|
        image(:"tile_#{n}", width: 8, height: 8, data: Array.new(64) { |at| ((at / 8) + n).even? ? :red : %i[blue green white yellow cyan magenta][n] })
        [n, :"tile_#{n}"]
      end
      tiles :set, images
      field = background :field, tiles: :set, map: Array.new(20) { Array.new(30) { 0 } }, held: held
      step = var :step, 0
      game_loop do
        step += 1
        10.times { |at| field.set_tile at * 3, (at % 4) + 2, step - 3 + at }
        field.set_tile 40, 3, step
      end
    end
  end

  private def colors_shown(held:)
    player = game_player
    player.run(game(held: held).program(console: VBlank::Testing.console), frames: 8)
    player.screen.to_a.flatten.uniq.length
  end

  def test_a_cell_given_a_worked_out_tile_shows_as_the_interpreter_shows_it
    assert_operator colors_shown(held: false), :>, 2, "the tiles are drawn"
  end

  def test_a_held_cell_given_a_worked_out_tile_shows_as_the_interpreter_shows_it
    assert_operator colors_shown(held: true), :>, 2, "the tiles are drawn"
  end
end
