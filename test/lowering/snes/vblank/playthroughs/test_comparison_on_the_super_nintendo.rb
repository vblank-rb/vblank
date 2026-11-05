# frozen_string_literal: true

require "test_helper"
require "stringio"

# TWO SUPER NINTENDO CARTRIDGES COMPARED on their own screen, 256 by 224 pixels, not the Advance's:
# a part of the screen past the Advance's 240 columns can be left out, and a difference is placed on
# the console's screen. The cartridges are small games built here: a white box on a blue field
# that walks two pixels a frame while RIGHT is down, from column +from+.
class TestComparisonOnTheSuperNintendo < Minitest::Test
  include VBlank::Testing::PlaysAlike

  private def walker(from)
    VBlank.build("WALKER", console: :snes, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 32 }
      box = sprite :box, at: [from, 60]
      game_loop { box.x += 2 if held(:right) }
    end
  end

  private def walk = VBlank.playthrough("walk right") { hold :right, frames: 10 }

  # The two boxes stand still near the right edge, four pixels apart; leaving out a part that reaches
  # past the Advance's last column, to the Super Nintendo's, is all that makes them alike.
  def test_a_part_of_the_screen_past_the_advance_s_can_be_left_out
    standing = VBlank.playthrough("stand") { wait frames: 20 }

    assert_raises(Minitest::Assertion) { assert_plays_alike walker(224), walker(228), standing }
    assert_plays_alike walker(224), walker(228), standing, ignoring_rectangles: [[224, 56, 32, 16]]
  end

  def test_a_difference_is_placed_on_the_console_s_screen
    failure = assert_raises(Minitest::Assertion) { assert_plays_alike walker(20), walker(28), walk }

    assert_match "pixels differ", failure.message
    assert_match(/box from \(2\d, 60\)/, failure.message)
  end
end
