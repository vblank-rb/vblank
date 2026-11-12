# frozen_string_literal: true

require "test_helper"
require "stringio"
require "slow_pass_games"

# TWO GENESIS CARTRIDGES COMPARED on their own screen, 320 by 224 pixels, not the Advance's: a part
# of the screen past the Advance's 240 columns can be left out, and a difference is placed on the
# console's screen. The cartridges are small games built here: a white box on a blue field that
# walks two pixels a frame while RIGHT is down, from column +from+.
class TestComparisonOnTheGenesis < Minitest::Test
  include VBlank::Testing::PlaysAlike
  include SlowPassGames

  private def walker(from)
    VBlank.build("WALKER", console: :genesis, out: StringIO.new, err: StringIO.new) do
      screen :tiled
      image(:box, "#" => :white) { "########\n" * 8 }
      image(:sea, "." => :blue) { "........\n" * 8 }
      tiles :set, "." => :sea
      background :field, tiles: :set, map: Array.new(32) { "." * 40 }
      box = sprite :box, at: [from, 60]
      game_loop { box.x += 2 if held(:right) }
    end
  end

  # Longer than the Super Nintendo's walk: the cartridge's start-up shows nothing for its first frames.
  private def walk = VBlank.playthrough("walk right") { hold :right, frames: 30 }

  def test_two_cartridges_of_one_game_play_alike
    assert_plays_alike walker(20), walker(20), walk
  end

  # The two boxes stand still near the right edge, four pixels apart; leaving out a part that reaches
  # past the Advance's last column, to the Genesis's, is all that makes them alike.
  def test_a_part_of_the_screen_past_the_advance_s_can_be_left_out
    standing = VBlank.playthrough("stand") { wait frames: 20 }

    assert_raises(Minitest::Assertion) { assert_plays_alike walker(288), walker(292), standing }
    assert_plays_alike walker(288), walker(292), standing, ignoring_rectangles: [[288, 56, 32, 16]]
  end

  def test_a_difference_is_placed_on_the_console_s_screen
    failure = assert_raises(Minitest::Assertion) { assert_plays_alike walker(20), walker(28), walk }

    assert_match "pixels differ", failure.message
    assert_match(/box from \(2\d, 60\)/, failure.message)
  end

  # Lined up by passes, a pass that finishes on its second frame is compared at its end
  # (SlowPassGames).
  def test_a_slow_pass_is_compared_at_its_end
    assert_slow_pass_compared_at_its_end(:genesis)
    assert_difference_found_at_pass_end(:genesis)
  end

  def test_a_drift_names_the_genesis_s_sprite_table
    drift = walk.compare(walker(20), walker(28)).drift

    assert_equal [:sprite_table], drift.video_differences.map(&:memory)
  end

  # Genesis Plus GX here draws every layer together, so a picture without its sprites cannot be had.
  def test_the_picture_without_sprites_is_refused_naming_the_console
    error = assert_raises(ArgumentError) { assert_plays_alike walker(20), walker(28), walk, layers: :backgrounds }

    assert_match "Genesis", error.message
    assert_match "`layers:`", error.message
  end
end
