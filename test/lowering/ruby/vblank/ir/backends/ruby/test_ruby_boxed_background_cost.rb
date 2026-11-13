# frozen_string_literal: true

require "test_helper"

# A BACKGROUND HELD TO A BOX, PAINTED BY THE RUBY RUNTIME. A Super Nintendo stage keeps its arena
# under a bar shown alone above a row, which holds the arena to the rows below it, and a game on the
# Advance can hold a background to a box it moves (`show_only_inside`). Either way the runtime used
# to paint the whole background onto a sheet and then lay each pixel inside the box through a
# method of its own, a few method calls a pixel: most of a big port's pass. A pixel of a box is
# laid with no method call of its own now. The count is the Ruby methods called in one more pass,
# which is exact where a time is not; the picture is held to the interpreter by
# test_background_above_row.rb and background_box_tests.rb, which this run plays.
class TestRubyBoxedBackgroundCost < Minitest::Test
  # The bar's row on the Super Nintendo, whose screen is 256 pixels wide and 224 tall.
  BAR_ROWS = 32
  ARENA_PIXELS = 256 * (224 - BAR_ROWS)
  # The box on the Advance, whose screen is 240 by 160.
  BOX = [8, 8, 224, 144].freeze
  BOX_PIXELS = BOX[2] * BOX[3]

  private def methods_called_playing(program, frames)
    game = VBlank::IR::Backends::Ruby.new.live_game(program)
    player = VBlank::Original::Unpacking::FrameLimitedPlayer.new(frames)
    calls = 0
    counting = TracePoint.new(:call) { calls += 1 }
    counting.enable { game.play(player) }
    calls
  end

  # The methods one more pass calls, with what starting the game calls taken away.
  private def methods_called_a_pass(program)
    (methods_called_playing(program, 12) - methods_called_playing(program, 2)) / 10
  end

  # An arena that scrolls every pass, so it is painted again every pass, under a bar shown alone
  # above row BAR_ROWS.
  private def arena_under_bar
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:floor_art, "#" => :red, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      image(:bar_art, "#" => :white) { (["#" * 8] * 8).join("\n") }
      tiles :floor_tiles, "a" => :floor_art
      tiles :bar_tiles, "a" => :bar_art
      floor = background :floor, tiles: :floor_tiles, map: Array.new(32) { "a" * 32 }
      background :bar, tiles: :bar_tiles, map: Array.new(4) { "a" * 32 }, above_row: BAR_ROWS, alone: true
      across = var :across, 0
      game_loop do
        across += 1
        floor.scroll_to across, 0
      end
    end
    b.finalize_program
    b.program
  end

  # A field held to BOX that scrolls every pass.
  private def field_in_box
    box = BOX
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    b.instance_eval do
      screen :tiled
      image(:field_art, "#" => :green, "." => :blue) { (["#.#.#.#."] * 8).join("\n") }
      tiles :field_tiles, "a" => :field_art
      field = background :field, tiles: :field_tiles, map: Array.new(32) { "a" * 32 }
      across = var :across, 0
      game_loop do
        across += 1
        field.scroll_to across, 0
        field.show_only_inside(*box)
      end
    end
    b.finalize_program
    b.program
  end

  def test_an_arena_under_a_bar_shown_alone_calls_fewer_methods_than_it_has_pixels
    assert_operator methods_called_a_pass(arena_under_bar), :<, ARENA_PIXELS / 4
  end

  def test_a_background_held_to_a_box_calls_fewer_methods_than_the_box_has_pixels
    assert_operator methods_called_a_pass(field_in_box), :<, BOX_PIXELS / 4
  end
end
