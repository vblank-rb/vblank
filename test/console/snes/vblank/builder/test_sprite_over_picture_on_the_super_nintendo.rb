# frozen_string_literal: true

require "test_helper"

# A sprite over a painted picture on the Super Nintendo (`sprite ..., over_picture: true`): the
# console's own sprite, drawn over the painted layer and never into it. The painted screen takes
# nearly all of video memory and the colour memory, so the sprite's tiles go in what it leaves and
# its colours in places of the colour memory the painting does not use (Runtime::Paint, "SPRITES
# over the picture"). Every run that plays games as the Super Nintendo plays these, so the cartridge
# and the game as C, JavaScript and Ruby are each held to the interpreter pass by pass. What every
# console does with such a sprite is test/all/vblank/builder/test_sprite_over_picture.rb; what the
# cartridge refuses and what it costs is
# test/lowering/snes/vblank/ir/backends/snes/test_snes_paint_sprites.rb.
class TestSpriteOverPictureOnTheSuperNintendo < Minitest::Test
  Color = VBlank::Graphics::Color

  STRIPES = "RRRRRRRR\nRRRRRRRR\nGGGGGGGG\nGGGGGGGG\nBBBBBBBB\nBBBBBBBB\n........\n........"
  STRIPE_COLORS = { "R" => :red, "G" => :green, "B" => :blue, "." => :transparent }.freeze

  # A sprite in the last corner of the Super Nintendo's screen, wider and taller than the Advance's,
  # over a field painted again every pass.
  def test_a_sprite_in_the_last_corner_of_the_wide_screen_shows
    game = VBlank.game("CORNER", consoles: %i[snes]) do
      screen :bitmap
      image(:stripes, STRIPE_COLORS) { STRIPES }
      sprite :stripes, at: [screen_width - 8, screen_height - 8], over_picture: true
      game_loop { clear_screen :cyan }
    end
    screen = game_player.run(game.program(console: :snes), frames: 6).screen

    assert_equal Color.resolve(:red), screen.pixel(screen.width - 1, screen.height - 8)
    assert_equal Color.resolve(:cyan), screen.pixel(screen.width - 1, screen.height - 1), "the see-through band"
  end

  # A fade darkens the sprite with the picture, and the view moved over the picture leaves the
  # sprite where it stands on the screen.
  def test_a_fade_reaches_the_sprite_and_the_camera_leaves_it_still
    game = VBlank.game("FADED", consoles: %i[snes]) do
      screen :bitmap
      image(:stripes, STRIPE_COLORS) { STRIPES }
      sprite :stripes, at: [100, 60], over_picture: true
      level = var :level, 0
      game_loop do
        clear_screen :cyan
        fill_rect 96, 56, 40, 40, :yellow
        level += 4
        fade :black, level
        camera 12, 6
      end
    end
    run = game_player.run(game.program(console: :snes), frames: 12)

    assert_operator run[:level], :>=, 20, "five passes or more were checked"
  end

  # Text written at a place known when the game is built, beside a sprite: the text is painted, and
  # the sprite's tiles keep the room text would take on a layer of its own.
  def test_text_beside_a_sprite_shows_as_the_interpreter_does
    game = VBlank.game("WORDS", consoles: %i[snes]) do
      screen :bitmap
      image(:stripes, STRIPE_COLORS) { STRIPES }
      ship = sprite :stripes, at: [40, 40], over_picture: true
      game_loop do
        clear_screen :black
        draw_text "SCORE", 8, 8, :white
        ship.x += 1
      end
    end
    screen = game_player.run(game.program(console: :snes), frames: 6).screen

    assert_includes (8...48).map { |x| screen.pixel(x, 10) }, Color.resolve(:white), "the words"
  end

  # Two hundred colours painted and a sprite of three: the painting's places keep clear of the
  # sprite's, and each shows its own colours.
  def test_a_picture_of_many_colours_and_a_sprite_each_show_their_own
    game = VBlank.game("COLOURS", consoles: %i[snes]) do
      screen :bitmap
      image(:stripes, STRIPE_COLORS) { STRIPES }
      sprite :stripes, at: [100, 160], over_picture: true
      game_loop do
        200.times { |i| fill_rect (i % 20) * 12, (i / 20) * 12, 12, 12, (i * 97) + 1 }
      end
    end
    screen = game_player.run(game.program(console: :snes), frames: 4).screen

    assert_equal Color.resolve((199 * 97) + 1), screen.pixel(235, 115), "the last colour painted"
    assert_equal Color.resolve(:green), screen.pixel(103, 163), "the sprite's middle band"
  end
end
