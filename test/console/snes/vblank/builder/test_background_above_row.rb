# frozen_string_literal: true

require "test_helper"
require "background_above_row_tests"

# A background held above a row of the screen, on the Super Nintendo: the tests every console that can hold
# one plays (BackgroundAboveRowTests).
class TestBackgroundAboveRow < Minitest::Test
  include BackgroundAboveRowTests

  private def built_for = :snes

  # A scene with an alone bar over a field every screen shows, and a scene the game never picks
  # holding a bar of its own above a lower row. That bar's line never runs, so it is on no screen:
  # the field shows on the rows between the two rows, and the build has room for both scenes.
  NEVER_ROWS = 48

  private def alone_bar_beside_scene_never_picked
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:field_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:bar_art, "#" => :white, "." => :transparent) { STEPS.join("\n") }
      tiles :field_set, "#" => :field_tile
      tiles :bar_set, "a" => :bar_art
      var :state, 0
      background :field, tiles: :field_set, map: Array.new(32) { "#" * 32 }
      scene(:held) { background :alone_bar, tiles: :bar_set, map: Array.new(4) { "a" * 32 }, above_row: ROWS, alone: true }
      scene(:never) { background :never_bar, tiles: :bar_set, map: Array.new(8) { "a" * 32 }, above_row: NEVER_ROWS }
      game_loop { call({ 0 => :held }, number: :state) }
    end
    b.finalize_program
    b.program
  end

  def test_a_bar_in_a_scene_never_picked_leaves_room_for_an_alone_bar
    screen = game_player.run(alone_bar_beside_scene_never_picked, frames: 4).screen

    assert_equal WHITE, screen.pixel(5, 1), "the alone bar"
    assert_equal BLACK, screen.pixel(1, 1), "the backdrop through the alone bar"
    assert_equal GREEN, screen.pixel(5, ROWS + 4), "the field, where the bar never picked would be"
  end

  # A field held to a box that slides right a pixel a pass and crosses an alone bar's row, beside
  # that bar. The box and the bar each take a part of the display of their own, so both work: the
  # box is a window that masks the field's layer (fullsnes, W12SEL and TMW), and the bar's row is a
  # line table that changes which layers the main screen shows (TM). The field shows only inside
  # the box and only from the bar's row down. With +walls+, a red background every
  # screen shows behind the field, so the bar goes on the third layer.
  BOX = [8, 16, 64, 48].freeze

  private def boxed_field_beside_alone_bar(walls: false)
    left, top, width, height = BOX
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :tiled
      image(:field_tile, "#" => :green) { (["#" * 8] * 8).join("\n") }
      image(:wall_tile, "#" => :red) { (["#" * 8] * 8).join("\n") }
      image(:bar_art, "#" => :white, "." => :transparent) { STEPS.join("\n") }
      tiles :field_set, "#" => :field_tile
      tiles :wall_set, "#" => :wall_tile
      tiles :bar_set, "a" => :bar_art
      background :walls, tiles: :wall_set, map: Array.new(32) { "#" * 32 } if walls
      field = background :field, tiles: :field_set, map: Array.new(32) { "#" * 32 }
      background :bar, tiles: :bar_set, map: Array.new(4) { "a" * 32 }, above_row: ROWS, alone: true
      passes = var :passes, 0
      game_loop do
        passes += 1
        field.show_only_inside left + passes, top, width, height
      end
    end
    b.finalize_program
    b.program
  end

  # A column inside the box on every pass played, and one left of it on every pass.
  IN_BOX_X = 28
  LEFT_OF_BOX_X = 8

  def test_a_field_held_to_a_box_beside_an_alone_bar
    [false, true].each do |walls|
      screen = game_player.run(boxed_field_beside_alone_bar(walls: walls), frames: 8).screen
      behind = walls ? RED : BLACK
      in_box_above_row = BOX[1] + 1

      assert_equal WHITE, screen.pixel(5, 1), "walls: #{walls}, the bar"
      assert_equal BLACK, screen.pixel(1, 1), "walls: #{walls}, the backdrop through the bar"
      assert_equal STEPS[in_box_above_row % 8][IN_BOX_X % 8] == "#" ? WHITE : BLACK, screen.pixel(IN_BOX_X, in_box_above_row),
                   "walls: #{walls}, in the box above the row, the bar alone"
      assert_equal GREEN, screen.pixel(IN_BOX_X, ROWS + 1), "walls: #{walls}, in the box below the row"
      assert_equal behind, screen.pixel(LEFT_OF_BOX_X, ROWS + 1), "walls: #{walls}, left of the box"
      assert_equal behind, screen.pixel(IN_BOX_X, BOX[1] + BOX[3] + 1), "walls: #{walls}, under the box"
    end
  end
end
