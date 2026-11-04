# frozen_string_literal: true

require "test_helper"

# A STATUS BAR BESIDE TWO BACKGROUNDS: an arena, clouds drifting over it, and a bar along the
# bottom, as a Super Bomberman stage shows them. The Super Nintendo puts the bar on its third
# layer, of four-colour tiles. Each pass is checked against the interpreter, and the picture says
# the order: the bar on its rows, the clouds over the arena above them, a sprite the layers put
# between the two behind the clouds and in front of the arena, and a sprite on the bar's rows over
# the bar.
class TestStatusBarBesideTwoBackgrounds < Minitest::Test
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  GREEN = VBlank::Graphics::Color.resolve(:green)
  YELLOW = VBlank::Graphics::Color.resolve(:yellow)
  WHITE = VBlank::Graphics::Color.resolve(:white)

  BAR_TOP = 208
  # The clouds stop once they have moved this far: then the screen's first 32 columns show the
  # arena between two clouds, and the next 32 a cloud.
  DRIFT = 32

  private def arena_clouds_and_bar
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:blue_art, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      image(:yellow_art, "#" => :yellow) { Minitest::Test::SOLID_TILE }
      %i[seen hidden over_bar].each { |ball| image(ball, "#" => :white) { Minitest::Test::SOLID_TILE } }
      tiles :arena_tiles, "#" => :red_art
      tiles :cloud_tiles, "o" => :blue_art
      tiles :bar_tiles, "g" => :green_art, "y" => :yellow_art
      layers :ground, :middle, :sky
      layer(:ground) { background :arena, tiles: :arena_tiles, map: Array.new(32) { "#" * 32 } }
      clouds = nil
      layer(:sky) { clouds = background :clouds, tiles: :cloud_tiles, map: Array.new(32) { "oooo    " * 4 } }
      layer :middle do
        sprite :seen, at: [4, 100]
        sprite :hidden, at: [36, 100]
        sprite :over_bar, at: [100, BAR_TOP + 2]
      end
      status_bar :score, tiles: :bar_tiles, map: ["gy" * 16, "gy" * 16], top: BAR_TOP
      moved = var :moved, 0
      game_loop do
        if moved < DRIFT
          moved += 8
          clouds.scroll_by 8, 0
        end
      end
    end
    b.finalize_program
    b.program
  end

  def test_the_bar_shows_on_its_rows_over_nothing_of_the_two_backgrounds
    screen = game_player.run(arena_clouds_and_bar, frames: 10).screen

    assert_equal GREEN, screen.pixel(4, BAR_TOP + 4)
    assert_equal YELLOW, screen.pixel(12, BAR_TOP + 4)
    assert_equal GREEN, screen.pixel(36, BAR_TOP + 12)
  end

  def test_the_clouds_are_over_the_arena_above_the_bar
    screen = game_player.run(arena_clouds_and_bar, frames: 10).screen

    assert_equal RED, screen.pixel(20, BAR_TOP - 1)
    assert_equal BLUE, screen.pixel(40, BAR_TOP - 1)
    assert_equal BLUE, screen.pixel(40, 20)
  end

  def test_a_sprite_between_them_is_behind_the_clouds_in_front_of_the_arena_and_over_the_bar
    screen = game_player.run(arena_clouds_and_bar, frames: 10).screen

    assert_equal WHITE, screen.pixel(6, 102)
    assert_equal BLUE, screen.pixel(38, 102)
    assert_equal WHITE, screen.pixel(102, BAR_TOP + 4)
  end
end
