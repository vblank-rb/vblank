# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

# TWO GAME BOY COLOR CARTRIDGES COMPARED on their own screen, 160 by 144 pixels: a part of the screen
# is left out by the Color's own corners, and one off it is refused naming the Color's size. The
# cartridges are small games built here: a white box on a blue field that walks two pixels a frame
# while RIGHT is down, from column +from+.
class TestComparisonOnTheColor < Minitest::Test
  include VBlank::Testing::PlaysAlike

  private def walker(from)
    VBlank.build("WALKER", console: :gbc, out: StringIO.new, err: StringIO.new) do
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

  # The second is a cartridge file, as an original is, so the screen's size is learned from it only
  # when it is opened.
  def test_two_color_cartridges_that_differ_in_one_part_pass_with_it_left_out
    Dir.mktmpdir do |folder|
      original = File.join(folder, "original.gbc").tap { walker(28).write(it) }

      assert_raises(Minitest::Assertion) { assert_plays_alike walker(20), original, walk }
      assert_plays_alike walker(20), original, walk, ignoring_rectangles: [[0, 56, 160, 16]]
    end
  end

  def test_a_part_looked_within_is_on_the_color_s_screen
    assert_plays_alike walker(20), walker(28), walk, looking_at: [[0, 0, 160, 56], [0, 72, 160, 72]]
  end

  def test_the_picture_without_sprites_forgives_a_sprite_elsewhere
    assert_plays_alike walker(20), walker(28), walk, layers: :backgrounds
  end

  def test_a_drift_names_the_color_s_sprite_table
    drift = walk.compare(walker(20), walker(28)).drift

    assert_includes drift.video_differences.map(&:memory), :sprite_table
    refute_includes drift.video_differences.map(&:memory), :colors
  end

  def test_a_rectangle_off_the_color_s_screen_is_refused_naming_its_size
    error = assert_raises(ArgumentError) { assert_plays_alike walker(20), walker(20), walk, ignoring_rectangles: [[150, 0, 20, 8]] }

    assert_match "160 pixels wide and 144 pixels high", error.message
  end
end
