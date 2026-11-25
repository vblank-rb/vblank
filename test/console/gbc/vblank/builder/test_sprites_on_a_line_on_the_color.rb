# frozen_string_literal: true

require "test_helper"

# Ten sprites on a line of the screen. The Color draws at most ten pieces of sprites on any one
# line, the first ten its sprite table holds there, and leaves the rest of that line's out. The
# table holds the sprite in front first, so on a crowded line the sprite furthest back is the one
# that goes: here the one declared first, which every other is drawn over. Only the crowded lines
# lose it; where it stands alone it is drawn.
class TestSpritesOnALineOnTheColor < Minitest::Test
  RED = Color.resolve(:red)
  GREEN = Color.resolve(:green)

  private def program(&block)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gbc))
    b.instance_eval(&block)
    b.finalize_program
    b.program
  end

  # A red square furthest back, standing four lines above a row of ten green squares beside it:
  # eleven pieces on lines 40..43, the red one alone on 36..39.
  private def crowded_line
    program do
      screen :tiled
      image(:red_square, "r" => :red) { (["r" * 8] * 8).join("\n") }
      image(:green_square, "g" => :green) { (["g" * 8] * 8).join("\n") }
      sprite :red_square, at: [0, 36]
      10.times { |i| sprite :green_square, at: [16 + (i * 10), 40] }
      game_loop {}
    end
  end

  def test_the_eleventh_sprite_on_a_line_is_left_out_of_that_line
    screen = game_player.run(crowded_line, frames: 3).screen

    refute_equal RED, screen.pixel(3, 40), "the red square is the eleventh on line 40, so it is left out"
    refute_equal RED, screen.pixel(3, 43), "and on every crowded line"
    assert_equal GREEN, screen.pixel(19, 41), "the first green square is drawn"
    assert_equal GREEN, screen.pixel(109, 41), "and the tenth"
  end

  # A square wholly off the left of the screen is not put in the sprite table, so it takes no
  # place on its lines: nine green squares on screen and one off it leave room for the red.
  def test_a_sprite_wholly_off_the_screen_takes_no_place_on_its_lines
    game = program do
      screen :tiled
      image(:red_square, "r" => :red) { (["r" * 8] * 8).join("\n") }
      image(:green_square, "g" => :green) { (["g" * 8] * 8).join("\n") }
      sprite :red_square, at: [0, 40]
      sprite :green_square, at: [-8, 40]
      9.times { |i| sprite :green_square, at: [16 + (i * 10), 40] }
      game_loop {}
    end
    screen = game_player.run(game, frames: 3).screen

    assert_equal RED, screen.pixel(3, 41)
  end

  # The Color counts every entry of its sprite table whose rows cross the line, whatever its x, so
  # an entry left at an x off the side still takes one of the ten (Pan Docs, "OAM", "Selection
  # priority"). The crowded line's greens are drawn for a few passes, then two go: the red one,
  # furthest back, must come back on the crowded line, and it can only if the two take no place.
  private def crowded_line_thinned(&thin)
    program do
      screen :tiled
      image(:red_square, "r" => :red) { (["r" * 8] * 8).join("\n") }
      image(:green_square, "g" => :green) { (["g" * 8] * 8).join("\n") }
      sprite :red_square, at: [0, 40]
      greens = Array.new(10) { |i| sprite :green_square, at: [16 + (i * 10), 40] }
      pass = var :pass, 0
      game_loop do
        pass += 1
        thin.call(greens) if pass == 3
      end
    end
  end

  def test_a_sprite_moved_off_the_side_takes_no_place_on_its_lines
    game = crowded_line_thinned do |greens|
      greens[0].move_to 200, 40
      greens[1].move_to 220, 40
    end
    refute_equal RED, game_player.run(game, frames: 1).screen.pixel(3, 41), "crowded at first: the red square is left out"
    screen = game_player.run(game, frames: 8).screen

    assert_equal RED, screen.pixel(3, 41), "two greens moved off the sides leave room for the red square"
  end

  def test_a_hidden_sprite_takes_no_place_on_its_lines
    game = crowded_line_thinned do |greens|
      greens[0].hide
      greens[1].hide
    end
    screen = game_player.run(game, frames: 8).screen

    assert_equal RED, screen.pixel(3, 41), "two hidden greens leave room for the red square"
  end

  def test_a_sprite_left_out_of_a_crowded_line_is_drawn_on_the_others
    screen = game_player.run(crowded_line, frames: 3).screen

    assert_equal RED, screen.pixel(3, 36), "the red square is alone on line 36"
    assert_equal RED, screen.pixel(3, 39), "and on line 39"
  end
end
