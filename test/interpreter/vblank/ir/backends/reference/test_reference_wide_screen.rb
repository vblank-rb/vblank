# frozen_string_literal: true

require "test_helper"

# A background is a torus, so on a screen wider than its grid it comes round: a map of 24 tiles across
# sits in a grid of 32 cells (256 pixels), and the Genesis's screen is 320 across, so its last 64 pixels
# show the map again from its first tile. The console's plane does this whatever put the map there
# (it is how a plane is read), so the picture a background is put up with agrees with the one a
# scroll of 0 repaints it as.
class TestReferenceWideScreen < Minitest::Test
  Color = VBlank::Graphics::Color

  private def game(&)
    builder = Builder.new
    builder.instance_eval(&)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  private def wide_room(scrolling: false)
    game do
      screen :tiled
      image(:wall, "#" => :white) { "########\n" * 8 }
      tiles :set, "#" => :wall
      room = background :room, tiles: :set, map: Array.new(4) { "#" * 24 }
      game_loop { room.scroll_to 0, 0 if pressed(:a) } if scrolling
      game_loop {} unless scrolling
    end
  end

  def test_a_background_put_up_comes_round_on_a_screen_wider_than_its_grid
    screen = Reference.new.run(wide_room, frames: 2).screen

    assert_equal Color.resolve(:white), screen.pixel(0, 0)
    assert_equal Color.resolve(:white), screen.pixel(256, 0), "the first tile again, after the grid's 32 cells"
    assert_equal Color.resolve(:white), screen.pixel(319, 31)
    assert_equal 0, screen.pixel(192, 0), "the grid's cells past the map's 24 have no tile"
    assert_equal 0, screen.pixel(0, 32), "and the rows past the map's 4 none"
  end

  def test_the_picture_of_a_background_put_up_is_the_one_a_scroll_of_nought_repaints
    put_up = Reference.new.run(wide_room, frames: 2).screen.shown
    scrolled = Reference.new.input_each_frame { |frame| frame == 1 ? [:a] : [] }.run(wide_room(scrolling: true), frames: 3)
                        .screen.shown

    assert scrolled == put_up, "the two pictures differ"
  end
end
