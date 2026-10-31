# frozen_string_literal: true

require "test_helper"
require "differential"
require "status_bar_games"

# What a game does with a status bar's handle as it runs: moves its top (`move_to`, read back with
# `top`), and changes one of its cells (`set_tile`). What the bar is and where it shows is the
# verb's own test, test/all/vblank/builder/test_status_bar.rb.
class TestStatusBarHandle < Minitest::Test
  include Differential
  include StatusBarGames

  # The game slides the bar down three rows a pass until it is out of view, and the field shows
  # at the bottom of the screen again. A row past the bottom is the bottom.
  def test_the_bar_slides_down_out_of_view_and_the_field_shows_under_it
    prog = bar_game { |bar, step| bar.move_to bar.top + 3 if step > 1 }
    bottom = screen_height - 1

    assert_equal GREEN, picture(prog, 2).pixel(8, bottom)
    refute_equal GREEN, picture(prog, 12).pixel(8, bottom), "the bar is out of view"
    refute_equal BLACK, picture(prog, 12).pixel(8, bottom), "and the field is drawn there"
    assert_backends_agree(prog, frames: [4, 6, 12], name: "BARSLIDE")
  end

  # A row above the top of the screen is the top: the whole screen is the bar.
  def test_a_bar_moved_above_the_top_covers_the_whole_screen
    prog = bar_game { |bar, _step| bar.move_to(-20) }

    assert_equal GREEN, picture(prog, 4).pixel(8, 8)
    assert_equal BLACK, picture(prog, 4).pixel(8, 40), "past its two rows"
    assert_backends_agree(prog, frames: 4, name: "BARTOP")
  end

  # One cell of the bar changes, the way a digit of a score does.
  def test_set_tile_changes_a_cell_of_the_bar
    prog = bar_game { |bar, step| bar.set_tile 3, 0, "o" if step == 2 }
    row = screen_height - 12

    assert_equal GREEN, picture(prog, 2).pixel(28, row)
    assert_equal BLUE, picture(prog, 5).pixel(28, row)
    assert_equal GREEN, picture(prog, 5).pixel(20, row), "the cell beside it"
    assert_backends_agree(prog, frames: 5, name: "BARCELL")
  end

  # Cells along the bar's top row, a pair a pass, each column worked out as a byte that comes
  # round (the way scrolling text finds its cells). One walks from 252: off the bar's 32 columns
  # until it comes round to 0 and onto it. The other walks from 28 off the bar's right edge, and a
  # column past it must not land on the start of the next row. A row past the bar's two changes
  # nothing either.
  def test_set_tile_at_a_column_worked_out_as_a_byte_changes_only_cells_on_the_bar
    prog = bar_game do |bar, step|
      bar.set_tile((step + 252) & 0xFF, 0, "o")
      bar.set_tile((step + 28) & 0xFF, 0, "o")
      bar.set_tile(step & 0xFF, 2, "o")
    end
    row = screen_height - 12
    seen = picture(prog, 12)

    (0..5).each { |column| assert_equal BLUE, seen.pixel((column * 8) + 4, row), "column #{column}" }
    assert_equal GREEN, seen.pixel((9 * 8) + 4, row), "column 9 is not reached yet"
    (0..9).each { |column| assert_equal GREEN, seen.pixel((column * 8) + 4, row + 8), "the second row's column #{column}" }
    assert_backends_agree(prog, frames: 13, name: "BARBYTE")
  end

  # A whole bar changes at once by showing another of its maps: more cells than a pass can change
  # one at a time, the way a two-row message is cleared.
  def test_show_map_changes_the_whole_bar_in_one_call
    prog = bar_game_with_maps { |bar, step| bar.show_map :blue if step == 3 }
    row = screen_height - 12

    assert_equal GREEN, picture(prog, 2).pixel(28, row)
    assert_equal BLUE, picture(prog, 6).pixel(28, row)
    assert_equal BLUE, picture(prog, 6).pixel(screen_width - 4, screen_height - 4), "the second row too"
    assert_backends_agree(prog, frames: 6, name: "BARMAP")
  end

  # A cell written in the pass the map changes shows over the new map, not under it: the game
  # clears the bar and writes the first letter of the next message together.
  def test_set_tile_in_the_pass_of_show_map_shows_over_the_new_map
    prog = bar_game_with_maps do |bar, step|
      if step == 2
        bar.show_map :blue
        bar.set_tile 3, 0, "#"
      end
    end
    row = screen_height - 12

    assert_equal GREEN, picture(prog, 6).pixel(28, row), "the cell written after the map"
    assert_equal BLUE, picture(prog, 6).pixel(20, row), "the cell beside it"
    assert_backends_agree(prog, frames: 6, name: "BARMAPCELL")
  end

  # A cell changed on the map that is showing is forgotten when another map goes up, and the first
  # map comes back as it was declared. The cell here is changed in the very pass the map goes, so
  # the new map must replace it even though the cell has not reached the screen yet.
  def test_show_map_forgets_a_cell_changed_before_it
    prog = bar_game_with_maps do |bar, step|
      if step == 2
        bar.set_tile 3, 0, "o"
        bar.show_map :blue
      end
      bar.show_map :green if step == 5
    end
    row = screen_height - 12

    assert_equal GREEN, picture(prog, 9).pixel(28, row)
    assert_backends_agree(prog, frames: 9, name: "BARMAPBACK")
  end

  # Showing the map that is up leaves a cell the game changed on it alone.
  def test_show_map_of_the_map_up_changes_nothing
    prog = bar_game_with_maps do |bar, step|
      bar.set_tile 3, 0, "o" if step == 2
      bar.show_map :green if step == 3
    end
    row = screen_height - 12

    assert_equal BLUE, picture(prog, 6).pixel(28, row)
    assert_backends_agree(prog, frames: 6, name: "BARMAPSAME")
  end
end
