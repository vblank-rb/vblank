# frozen_string_literal: true

require "test_helper"

# HOW FAR A WALK OF THE COLOURS GOES (Backends::PaletteWalk), held once for every console: a fade or
# tint the game works out past either end goes all the way or none of it. Played through
# game_player, so each run's console walks them its own way and is checked against the interpreter
# on every pass. What only a console's own build shows, the cost and the refusals, is in
# test/palette_walk_tests.rb.
class TestPaletteWalk < Minitest::Test
  RED = VBlank::Graphics::Color.resolve(:red)
  BLUE = VBlank::Graphics::Color.resolve(:blue)
  BLACK = VBlank::Graphics::Color.resolve(:black)
  WHITE = VBlank::Graphics::Color.resolve(:white)

  # A red wall faded by +first+ on the first pass and +last+ on every pass after, both worked out
  # as the game runs; the wall's colour after a few passes.
  private def wall_after(toward, first, last)
    tile = SOLID_TILE
    walk = toward
    b = Builder.new
    b.instance_eval do
      screen :tiled
      image(:brick, "#" => :red) { tile }
      tiles :wall, "#" => :brick
      background :wall, tiles: :wall, map: Array.new(20) { "#" * 30 }
      level = var :level, first
      pass = var :pass, 0
      game_loop do
        pass += 1
        level = last if pass > 1
        walk == :blue ? tint(:blue, level) : fade(walk, level)
      end
    end
    b.finalize_program
    game_player.run(b.program, frames: 5).screen.pixel(8, 8)
  end

  def test_a_fade_worked_out_past_the_end_goes_all_the_way_and_no_further
    assert_equal BLACK, wall_after(:black, 40, 150)
    assert_equal WHITE, wall_after(:white, 40, 3000)
  end

  def test_a_fade_worked_out_below_nought_is_none
    assert_equal RED, wall_after(:black, 60, -20)
  end

  def test_a_tint_worked_out_past_both_ends_is_all_or_none
    assert_equal BLUE, wall_after(:blue, 30, 400)
    assert_equal RED, wall_after(:blue, 30, -400)
  end
end
