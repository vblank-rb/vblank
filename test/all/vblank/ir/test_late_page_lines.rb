# frozen_string_literal: true

require "test_helper"

# Which of the console's lines a late page is still shown at once above (IR::LatePages#lines_above):
# the game's row, counted down the console's whole screen. A game laid out for the Color and shown
# in the Advance's border starts its screen 8 lines down, so its rows are 8 lines further down
# there than on the Color, and showing a late page "anywhere" is anywhere on the whole screen.
class TestLatePageLines < Minitest::Test
  # A tear-free screen that shows a late page at once above +late+.
  private def game(late)
    VBlank.game("LATEROWS", consoles: %i[gbc gba], variants: { gba: :color_screen }) do
      screen :bitmap, tear_free: true, late: late
      game_loop { clear_screen :black }
    end
  end

  private def lines_on(console, late)
    pages = VBlank::IR::LatePages.of(game(late).program(console: console))
    pages.lines_above(pages.game_setting)
  end

  def test_a_row_is_where_the_game_screen_has_it
    assert_equal 40, lines_on(:gbc, 40)
    assert_equal 48, lines_on(:gba, 40), "eight lines down, below the border's top"
  end

  def test_show_now_is_every_line_of_the_whole_screen
    assert_equal 144, lines_on(:gbc, :show_now)
    assert_equal 160, lines_on(:gba, :show_now)
  end

  def test_a_screen_that_waits_has_no_lines
    assert_nil lines_on(:gba, :wait)
  end
end
