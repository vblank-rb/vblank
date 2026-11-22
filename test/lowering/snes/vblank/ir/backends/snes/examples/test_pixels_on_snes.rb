# frozen_string_literal: true

require "test_helper"
# A plain require, not ShareableConstants.require_file: Pixels is a game written at the top of its
# file, so its block belongs to Ruby's top-level object and cannot be shared.
require VBlank.root.join("examples/pixels").to_s

# examples/pixels.rb on a Super Nintendo: placed from the screen's own size, so the flag is in the
# middle of its 256×224 screen and a marker is in each of its corners — held to the interpreter,
# every pixel, when the game halts.
class TestPixelsOnSNES < Minitest::Test
  # The game's block belongs to Ruby's top-level object, which only the main Ractor may use; and a
  # program built from it ahead cannot be kept frozen, since a build notes what it works out on the
  # program's own nodes.
  runs_on_the_main_ractor!

  Color = VBlank::Graphics::Color

  def test_the_flag_is_in_the_middle_and_the_markers_in_the_corners
    run = game_player.run(Pixels.program(console: game_console), frames: 4)
    screen = run.screen
    width = screen.width
    height = screen.height

    assert_equal [256, 224], [width, height]
    assert_equal Color.resolve(:yellow), screen.pixel(0, 0)
    assert_equal Color.resolve(:cyan), screen.pixel(width - 1, 0)
    assert_equal Color.resolve(:magenta), screen.pixel(0, height - 1)
    assert_equal Color.resolve(:white), screen.pixel(width / 2, height / 2), "the flag's white stripe is in the middle"
  end
end
