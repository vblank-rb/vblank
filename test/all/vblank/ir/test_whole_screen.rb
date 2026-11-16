# frozen_string_literal: true

require "test_helper"

# Which statements paint over the whole screen, asked the two ways IR::WholeScreen answers: by
# the sprites' bookkeeping and by the warning about a sprite cleared every frame. Hand-built
# statements, since both read the tree and not a running game.
class TestWholeScreen < Minitest::Test
  include VBlank::IR::Build

  WholeScreen = VBlank::IR::WholeScreen
  SCREEN = [240, 160].freeze

  def test_a_clear_covers_the_screen
    assert WholeScreen.covers_screen?(clear_screen(:blue), SCREEN)
  end

  def test_a_fill_from_the_corner_as_big_as_the_screen_covers_it
    assert WholeScreen.covers_screen?(fill_rect(0, 0, 240, 160, :blue), SCREEN)
    assert WholeScreen.covers_screen?(dma_fill_rect(0, 0, 240, 160, :blue), SCREEN)
    assert WholeScreen.covers_screen?(draw_rect_at(0, 0, 240, 160, :blue), SCREEN), "numbers written as values"
  end

  def test_a_fill_hanging_off_every_edge_covers_the_screen
    assert WholeScreen.covers_screen?(fill_rect(-8, -8, 256, 176, :blue), SCREEN)
  end

  def test_a_fill_that_misses_an_edge_does_not_cover_the_screen
    refute WholeScreen.covers_screen?(fill_rect(1, 0, 240, 160, :blue), SCREEN), "the first column is left"
    refute WholeScreen.covers_screen?(fill_rect(0, 0, 240, 159, :blue), SCREEN), "the last row is left"
    refute WholeScreen.covers_screen?(fill_rect(120, 0, 120, 160, :blue), SCREEN)
    refute WholeScreen.covers_screen?(fill_rect(8, 8, 240, 160, :blue), SCREEN), "a screen's size, started inside it"
  end

  def test_a_fill_whose_place_or_size_the_game_works_out_does_not_cover_the_screen
    refute WholeScreen.covers_screen?(draw_rect_at(var_ref(:x), 0, 240, 160, :blue), SCREEN)
    refute WholeScreen.covers_screen?(draw_rect_at(0, 0, var_ref(:w), 160, :blue), SCREEN)
  end

  def test_other_paintings_do_not_cover_the_screen
    refute WholeScreen.covers_screen?(pixel(0, 0, :blue), SCREEN)
  end

  # The warning's question is wider: a fill a screen in size wipes the field under a sprite
  # wherever it starts, a place the game works out included. Its size must still be written.
  def test_a_fill_a_screen_in_size_is_screen_sized_wherever_it_starts
    assert WholeScreen.screen_sized?(clear_screen(:blue), SCREEN)
    assert WholeScreen.screen_sized?(fill_rect(8, 8, 240, 160, :blue), SCREEN)
    assert WholeScreen.screen_sized?(draw_rect_at(var_ref(:x), 0, 240, 160, :blue), SCREEN)
    refute WholeScreen.screen_sized?(draw_rect_at(0, 0, var_ref(:w), 160, :blue), SCREEN)
    refute WholeScreen.screen_sized?(fill_rect(0, 0, 239, 160, :blue), SCREEN)
    refute WholeScreen.screen_sized?(pixel(0, 0, :blue), SCREEN)
  end
end
