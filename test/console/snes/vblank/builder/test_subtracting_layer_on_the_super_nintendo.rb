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

  # A see-through layer on each of two screens that never show together: the title's words added
  # to the sand behind them, then the arena's light taking the sand away. The colour maths is told
  # each screen's own layers as the screen arrives, and the checked run holds every pass to the
  # interpreter, the passes just after the change among them.
  private def title_then_arena_pixels(title)
    game = title_then_lit_arena(**title)
    at_title = game_player.run(game, frames: 4).screen.pixel(*LIT_ARENA)
    at_arena = game_player.input_each_frame { |frame| frame == 5 ? [:a] : [] }.run(game, frames: 10).screen
    [at_title, at_arena.pixel(*LIT_ARENA), at_arena.pixel(*LIT_WALKER), at_arena.pixel(*DARK_ARENA)]
  end

  def test_each_screen_shows_its_own_see_through_layer_added_then_subtracted
    title, lit, walker, dark = title_then_arena_pixels(shows: 100, shows_behind: 100)

    assert_equal rgb5(31, 18, 31), title, "the title's words added to the sand, stopped at the brightest"
    assert_equal rgb5(18, 6, 27), lit, "the arena's light, the sand taken away"
    assert_equal rgb5(24, 0, 29), walker, "the arena's light over the walker"
    assert_equal rgb5(*ARENA), dark, "the arena where there is no light"
  end

  def test_a_half_see_through_title_then_a_subtracting_arena
    title, lit, = title_then_arena_pixels(transparency: 50)

    assert_equal rgb5(19, 9, 17), title, "half the title's words over half the sand"
    assert_equal rgb5(18, 6, 27), lit, "the arena's light, the sand taken away"
  end

  # A bar held alone above a row beside the arena and its light, as a console's own status bar is:
  # above the row the bar shows as drawn, with no colour maths, and below it the light mixes with
  # what is behind it.
  private def screen_under_a_bar(subtract:) = screen_of(lit_arena_under_a_bar(subtract: subtract))

  def test_a_bar_above_the_row_shows_unmixed_over_a_subtracting_light
    screen = screen_under_a_bar(subtract: true)

    assert_equal rgb5(*BAR), screen.pixel(*BAR_OVER_LIGHT), "the bar where the light is under it"
    assert_equal rgb5(*BAR), screen.pixel(*BAR_OVER_DARK), "the bar where there is no light"
    assert_equal rgb5(18, 6, 27), screen.pixel(*LIT_BELOW_BAR), "the light below the bar, the sand taken away"
    assert_equal rgb5(24, 0, 29), screen.pixel(*LIT_WALKER), "the light over the walker"
    assert_equal rgb5(*ARENA), screen.pixel(*DARK_ARENA), "the arena where there is no light"
  end

  def test_a_bar_above_the_row_shows_unmixed_over_an_adding_light
    screen = screen_under_a_bar(subtract: false)

    assert_equal rgb5(*BAR), screen.pixel(*BAR_OVER_LIGHT), "the bar where the light is under it"
    assert_equal rgb5(*BAR), screen.pixel(*BAR_OVER_DARK), "the bar where there is no light"
    assert_equal rgb5(31, 18, 31), screen.pixel(*LIT_BELOW_BAR), "the light added to the sand"
    assert_equal rgb5(31, 31, 31), screen.pixel(*LIT_WALKER), "the light added to the walker"
  end
end
