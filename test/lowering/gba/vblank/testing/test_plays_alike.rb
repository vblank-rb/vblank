# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "comparison_games"

# A port's test holds its cartridge to the original with one assertion, assert_plays_alike, and a
# failure says where and how the two parted. The two cartridges here are the walker and the walker
# that draws a few white specks from tick SPECKS_FROM, built in the test; the second is written to a
# file, as an original is.
class TestPlaysAlike < Minitest::Test
  include ComparisonGames
  include VBlank::Testing::PlaysAlike

  def test_two_cartridges_that_play_alike_pass
    assert_plays_alike walker, walker, walk_right
  end

  def test_a_failure_says_where_and_how_the_pictures_parted
    Dir.mktmpdir do |folder|
      original = File.join(folder, "original.gba").tap { walker(specks: 3).write(it) }

      failure = assert_raises(Minitest::Assertion) { assert_plays_alike walker, original, walk_right }

      assert_match "the picture", failure.message
      assert_match "3 pixels differ", failure.message
      assert_match "(#{SPECK_X}, #{SPECK_Y}), 3 wide and 1 high", failure.message
    end
  end

  def test_a_part_left_out_lets_the_two_pass
    assert_plays_alike walker, walker(specks: 3), walk_right, ignoring_rectangles: [[SPECK_X, SPECK_Y, 3, 1]]
  end

  def test_a_failure_gives_the_readings_on_both
    readings = { paces: :paces }

    failure = assert_raises(Minitest::Assertion) do
      assert_plays_alike walker, walker(counts_by: 2), walk_right, readings: readings, comparing: [:readings]
    end

    assert_match "paces", failure.message
  end
end
