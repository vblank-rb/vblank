# frozen_string_literal: true

require "test_helper"

# A PICTURE PAINTED FROM A LIST ON THE COLOR. The Color has no list of sizes a sprite is drawn at:
# every picture is pieces of 8×8, so a painted one can be any size in whole pieces, where the
# Advance holds it to the twelve sizes it draws a sprite at whole.
class TestTileRunsOnTheColor < Minitest::Test
  # A picture of 24×8, three tiles, whose third tile alone is painted.
  private def painted_wide_picture
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval do
      screen :tiled
      colors :ink, [:transparent, :white]
      canvas = list :canvas, capacity: 96, width: :byte
      repeat(64) { canvas.push 0 }
      repeat(32) { canvas.push 0x11 }
      tag = image :tag, from: canvas, width: 24, height: 8, colors: :ink
      sprite :tag, at: [40, 20]
      game_loop { tag.changed }
    end
    b.finalize_program
    b.program
  end

  def test_a_painted_picture_of_no_size_the_advance_draws_shows_every_tile
    screen = game_player.run(painted_wide_picture, frames: 4).screen

    assert_equal 0, screen.pixel(44, 22), "the first tile is see-through"
    assert_equal Color.resolve(:white), screen.pixel(60, 22), "the third tile is painted"
  end
end
