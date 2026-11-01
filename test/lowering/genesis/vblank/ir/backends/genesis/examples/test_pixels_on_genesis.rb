# frozen_string_literal: true

require "test_helper"
require VBlank.root.join("examples/pixels").to_s

# examples/pixels.rb on a Genesis: placed from the screen's own size, so the flag is in the middle of
# its 320×224 screen and a marker is in each of its corners — held to the interpreter, every pixel,
# when the game halts. Each colour it paints is one a Genesis shows exactly, since it names
# colours whose channels are all or nothing.
class TestPixelsOnGenesis < Minitest::Test
  Color = VBlank::Graphics::Color

  def test_the_flag_is_in_the_middle_and_the_markers_in_the_corners
    run = game_player.run(Pixels.program(console: game_console), frames: 4)
    screen = run.screen
    width = screen.width
    height = screen.height

    assert_equal [320, 224], [width, height]
    assert_equal Color.resolve(:yellow), screen.pixel(0, 0)
    assert_equal Color.resolve(:cyan), screen.pixel(width - 1, 0)
    assert_equal Color.resolve(:magenta), screen.pixel(0, height - 1)
    assert_equal Color.resolve(:white), screen.pixel(width / 2, height / 2), "the flag's white stripe is in the middle"
  end

  def test_the_flag_is_three_stripes_and_the_dots_are_under_it
    screen = game_player.run(Pixels.program(console: game_console), frames: 4).screen
    middle = screen.height / 2

    assert_equal [Color.resolve(:green) & 0x03E0, Color.resolve(:white), Color.resolve(:red)],
                 [110 + 5, 110 + 33 + 5, 110 + 66 + 5].map { |x| screen.pixel(x, middle) }
    assert_equal Color.resolve(:red), screen.pixel(110 + 35, 82 + 70)
    assert_equal Color.resolve(:blue), screen.pixel(110 + 35 + 20, 82 + 70)
  end
end
