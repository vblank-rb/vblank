# frozen_string_literal: true

require "test_helper"
require "stringio"
require "comparison_games"

# THE STRICT RULE FOR TORN FRAMES (`forgiving_torn_frames_of:`). An original that copies a change
# in while the screen is drawn shows it torn for a frame: part old, part new, unlike the frame
# before it and the frame after. The rule forgives that frame only where the other cartridge
# already shows what the torn one settles on, which `frames_in_a_row:` cannot tell from a fault of
# a frame in the other cartridge.
#
# The cartridges are a blue screen that turns red on tick TURNS, built here. The "original" shows
# tick TURNS torn, its top half red and its bottom half still blue, and is all red from the tick
# after. Ours turns all red on tick TURNS (what the original settles on), or one tick late.
class TestComparisonTornFrames < Minitest::Test
  include ComparisonGames
  include VBlank::Testing::PlaysAlike

  TURNS = 20

  # Each frame is drawn whole on a page of its own and shown when done, so the only torn frame is
  # the one drawn torn on purpose.
  private def turning(torn: false, late: 0)
    VBlank.build("TURNING", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap, tear_free: true
      ticks = var :ticks, 0
      game_loop do
        ticks += 1
        if ticks < TURNS + late
          clear_screen :blue
        else
          clear_screen :red
          fill_rect 0, 80, 240, 80, :blue if torn && ticks == TURNS
        end
      end
    end
  end

  private def watch = VBlank.playthrough("watch") { wait frames: 40 }

  def test_a_torn_frame_is_forgiven_where_ours_shows_what_it_settles_on
    assert_raises(Minitest::Assertion) { assert_plays_alike turning, turning(torn: true), watch }
    assert_plays_alike turning, turning(torn: true), watch, forgiving_torn_frames_of: :second
  end

  # Ours a frame late is blue where the original is torn, and the original settles on red: that
  # is a fault of ours the torn frame was hiding, and `frames_in_a_row: 2` lets it pass.
  def test_ours_a_frame_late_beside_a_torn_frame_is_drift
    late = turning(late: 1)
    original = turning(torn: true)

    assert_plays_alike late, original, watch, frames_in_a_row: 2
    drift = watch.compare(late, original, forgiving_torn_frames_of: :second).drift
    refute_nil drift
    assert_equal [:picture], drift.differed
  end

  # The rule is for the side said: a frame of ours that is unlike the frames either side of it is
  # still drift.
  def test_a_torn_frame_of_the_other_side_is_not_forgiven
    assert_raises(Minitest::Assertion) do
      assert_plays_alike turning(torn: true), turning, watch, forgiving_torn_frames_of: :second
    end
    assert_plays_alike turning(torn: true), turning, watch, forgiving_torn_frames_of: :first
  end

  # The drift's frame is the torn frame, the frame ours fell behind on.
  def test_the_drift_is_on_the_torn_frame
    late = turning(late: 1)
    original = turning(torn: true)
    torn_on = first_frame(original, watch.play(original).tape) { |game| game.red?(0, 0) }

    assert_equal torn_on, watch.compare(late, original, forgiving_torn_frames_of: :second).drift.frame
  end

  def test_carrying_on_with_the_rule_lists_only_the_real_drift
    result = watch.compare(turning(late: 1), turning(torn: true), forgiving_torn_frames_of: :second, carrying_on: true)

    assert_equal 1, result.drifts.size
    assert result.drift.back_in_step?
  end

  def test_a_side_that_is_neither_is_refused
    error = assert_raises(ArgumentError) { watch.compare(nil, nil, forgiving_torn_frames_of: :original) }

    assert_match "`forgiving_torn_frames_of:`", error.message
  end

  def test_the_rule_is_refused_on_the_same_script
    watched = VBlank.playthrough("watch") do
      wait frames: 40
      moment :watched
    end
    error = assert_raises(ArgumentError) { watched.compare(nil, nil, same: :script, forgiving_torn_frames_of: :second) }

    assert_match "same script", error.message
  end
end
