# frozen_string_literal: true

require "test_helper"

# A SPRITE PICTURE LONGER THAN ANY THE ADVANCE DRAWS WHOLE. The Color draws every picture as pieces
# of 8×8, up to forty at once and ten on a row of the screen, so a picture too tall for the Advance
# fits where it is few pieces. Its far end has to land where the interpreter puts it, and it has to
# walk off the edge of the screen. One wider than ten pieces is refused (test_gbc_refusals.rb).
class TestBigSpritePicturesOnTheColor < Minitest::Test
  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)

  private def program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # 8×96, twelve pieces: red, with a green last piece.
  private def tall_picture
    program do
      screen :tiled
      art = ((["r" * 8] * 88) + (["g" * 8] * 8)).join("\n")
      image(:pole, "r" => :red, "g" => :green) { art }
      pole = sprite :pole, at: [40, 4]
      game_loop { pole.y -= 2 }
    end
  end

  def test_a_picture_of_twelve_pieces_shows_its_far_end
    screen = game_player.run(tall_picture, frames: 2).screen

    assert_equal RED, screen.pixel(42, 4)
    assert_equal GREEN, screen.pixel(42, 88), "ninety-odd pixels along"
  end

  # Past the top edge, part of it stays on screen.
  def test_a_tall_picture_walks_off_the_top_edge
    screen = game_player.run(tall_picture, frames: 10).screen

    assert_equal GREEN, screen.pixel(42, 76)
  end
end
