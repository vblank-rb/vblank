# frozen_string_literal: true

require "test_helper"

# A STATUS BAR BESIDE A BACKGROUND SHOWN ALONE ABOVE ITS ROW WITHOUT SPRITES, on DOS, whose processor paints that
# background again over the sprites as it builds the view: only in the rows the bar leaves it, and only inside its
# box, as the interpreter paints it (Reference#paint_held_over_sprites). The other consoles that hold a background
# above a row cannot have a status bar beside it yet.
class TestStatusBarBesideHeldBackgroundOnDOS < Minitest::Test
  private def program(&loop_body)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :tiled
      image(:green_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:red_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:white_tile, "#" => :white) { (["#" * 8] * 8).join("\n") }
      image(:ball, "#" => :yellow) { (["#" * 8] * 8).join("\n") }
      tiles :field_set, "#" => :green_tile
      tiles :hud_set, "#" => :red_tile
      tiles :bar_set, "#" => :white_tile
      background :field, tiles: :field_set, map: Array.new(32) { "#" * 32 }
      hud = background :hud, tiles: :hud_set, map: Array.new(32) { "#" * 32 }, above_row: 32, alone: :without_sprites
      bar = status_bar :score, tiles: :bar_set, map: ["#" * 32, "#" * 32], top: 100
      sprite :ball, at: [40, 10]
      step = var :step, 0
      game_loop do
        step += 1
        instance_exec(bar, hud, step, &loop_body)
      end
    end
    b.finalize_program
    b.program
  end

  # The bar moved to the top row leaves the background no rows at all, so the bar shows in its first row too.
  def test_a_bar_at_the_top_row_leaves_the_held_background_no_rows
    screen = game_player.run(program { |bar, _hud, step| bar.move_to 0 if step == 2 }, frames: 8).screen

    assert_equal VBlank::Graphics::Color.resolve(:white), screen.pixel(0, 0)
  end

  # A row down, the background shows in that one row.
  def test_a_bar_a_row_down_leaves_the_held_background_its_first_row
    game_player.run(program { |bar, _hud, step| bar.move_to 1 if step == 2 }, frames: 8)
  end

  # Held to a box, it is painted over the sprites only inside the box; the rest of its rows are the backdrop.
  def test_the_held_background_is_painted_over_the_sprites_only_inside_its_box
    screen = game_player.run(program { |_bar, hud, _step| hud.show_only_inside(20, 0, 50, 100) }, frames: 8).screen

    assert_equal VBlank::Graphics::Color.resolve(:red), screen.pixel(40, 10), "inside the box, over the ball"
    assert_equal VBlank::Graphics::Color.resolve(:black), screen.pixel(100, 10), "outside it"
  end

  # Moved past the bottom, the bar shows nowhere, and nothing is painted past the screen.
  def test_a_bar_moved_past_the_bottom_shows_nowhere
    game_player.run(program { |bar, _hud, step| bar.move_to screen_height if step == 2 }, frames: 8)
  end
end
