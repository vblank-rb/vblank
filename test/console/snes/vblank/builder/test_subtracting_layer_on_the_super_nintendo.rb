# frozen_string_literal: true

require "test_helper"
require "subtracting_layer_games"

# A light that takes away what is behind it, `layer :light, ..., subtract: true`, on every run that
# plays games as the Super Nintendo. Its colour maths takes the sub screen (what is behind the
# layer) away from the main screen (the layer) a channel at a time, stopping at nothing, and can
# halve what is left (fullsnes, "Color Math": CGADSUB bit 7 subtracts, bit 6 halves). Not in
# test/all/: the Advance, the Color, the Genesis and the PlayStation refuse it, each in its folder.
#
# The colours are picked so the console's five-bit sum and the interpreter's eight-bit one come to
# the same pixel, so the numbers below are the picture on every run here.
class TestSubtractingLayerOnTheSuperNintendo < Minitest::Test
  include SubtractingLayerGames

  private def screen_of(program) = game_player.run(program, frames: 4).screen

  def test_a_subtracting_light_takes_away_the_arena_and_the_walker_behind_it
    screen = screen_of(lit_arena(shows: 100, shows_behind: 100))

    assert_equal rgb5(18, 6, 27), screen.pixel(*LIT_ARENA), "the light over the arena"
    assert_equal rgb5(24, 0, 29), screen.pixel(*LIT_WALKER), "the light over the walker, its green stopped at nothing"
    assert_equal rgb5(*ARENA), screen.pixel(*DARK_ARENA), "the arena where there is no light"
  end

  def test_a_halved_subtracting_light_shows_half_of_what_is_left
    [{ shows: 50, shows_behind: 50 }, { transparency: 50 }].each do |amounts|
      screen = screen_of(lit_arena(**amounts))

      assert_equal rgb5(9, 3, 13), screen.pixel(*LIT_ARENA), "the light over the arena, #{amounts}"
      assert_equal rgb5(12, 0, 14), screen.pixel(*LIT_WALKER), "the light over the walker, #{amounts}"
      assert_equal rgb5(*ARENA), screen.pixel(*DARK_ARENA), "the arena where there is no light, #{amounts}"
    end
  end
end
