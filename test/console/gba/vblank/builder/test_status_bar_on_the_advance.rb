# frozen_string_literal: true

require "test_helper"
require "differential"
require "status_bar_games"

# What a status bar does on the Advance, which the Color refuses (Checks::StatusBarCannotShare): a game
# with a painted screen too, and a sprite stacked behind the field.
class TestStatusBarOnTheAdvance < Minitest::Test
  include Differential
  include SpriteBehindFieldOverBarTests

  # A painted screen, then a tiled one with a bar moved to the top.
  def test_a_bar_beside_a_painted_screen
    prog = program do
      image(:red_art, "#" => :red) { SOLID_TILE }
      image(:green_art, "#" => :green) { SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      state = var :state, 0
      tick = var :tick, 0
      scene(:paint) do
        screen :bitmap
        fill_rect 0, 40, 40, 8, :blue
      end
      scene(:play) do
        screen :tiled
        background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
        bar = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: screen_height - 16
        bar.move_to 0
      end
      game_loop do
        tick += 1
        state = 1 if tick == 6
        state = 0 if tick == 12
        case_var(:state) do
          when_val 0, :paint
          when_val 1, :play
        end
      end
    end

    assert_equal GREEN, picture(prog, 10).pixel(8, 4), "the bar, at the top"
    assert_backends_agree(prog, frames: 10, console_frames: 12, name: "BARPAINT")
  end
end
