# frozen_string_literal: true

require "test_helper"
require "stringio"
require "comparison_games"

# TWO CARTRIDGES LINED UP BY THE GAME'S OWN PASSES (`by_passes:`), not by frames. A pass is one
# run of the game's loop, and on either cartridge one may take a frame or several: an original
# too busy for a frame now and then, a port that is quicker. Frame by frame such a pair drifts
# at the first slow pass and never comes back; pass by pass it is compared like with like, on
# the first frame each cartridge shows each pass.
#
# The cartridges are one small game built twice, the "late" one spending two frames on every
# fifth pass. Each counts its passes in a variable, moves a box while RIGHT is down, and moves a
# marker every pass, so every pass has a picture of its own.
class TestComparisonByPasses < Minitest::Test
  include ComparisonGames
  include VBlank::Testing::PlaysAlike

  # +late+ makes every fifth pass take two frames; +speck_on+ draws one white pixel on that pass
  # alone; +stops_at+ is the pass the count stops at, for a cartridge that never gets further.
  private def passing(late: false, speck_on: nil, stops_at: nil)
    VBlank.build("PASSING", console: :gba, frame_sync: :manual, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      passes = var :passes, 0
      x = var :x, 20
      game_loop do
        wait_vblank
        if late
          wait_vblank if passes % 5 == 4
        end
        if stops_at
          passes += 1 if passes < stops_at
        else
          passes += 1
        end
        x += 2 if held(:right)
        clear_screen :blue
        draw_rect_at x, 60, 8, 8, :white
        draw_rect_at passes % 200, 100, 4, 4, :green
        pixel 120, 130, :white if speck_on && passes == speck_on
      end
    end
  end

  private def walk
    VBlank.playthrough "walk" do
      wait frames: 6
      moment :standing
      hold :right, frames: 12
      moment :walked
      wait frames: 20
    end
  end

  private def watch = VBlank.playthrough("watch") { wait frames: 40 }

  def test_a_slow_pass_drifts_frame_by_frame_and_not_pass_by_pass
    assert_raises(Minitest::Assertion) { assert_plays_alike passing, passing(late: true), watch }
    assert_plays_alike passing, passing(late: true), watch, by_passes: :passes
    assert_plays_alike passing(late: true), passing, watch, by_passes: :passes
  end

  # The second cartridge is held each pass's buttons, the ones the first held on the frame it
  # showed that pass, so a press lands on the same pass on both though not on the same frame.
  def test_presses_land_on_the_same_pass_on_both
    assert_raises(Minitest::Assertion) { assert_plays_alike passing, passing(late: true), walk, readings: { x: :x } }
    assert_plays_alike passing, passing(late: true), walk, by_passes: :passes, readings: { x: :x }
    assert_plays_alike passing(late: true), passing, walk, by_passes: :passes, readings: { x: :x }
  end

  def test_a_difference_on_one_pass_is_found_on_that_pass
    first = passing
    second = passing(late: true, speck_on: 12)
    tape = watch.play(first).tape
    drift = watch.compare(first, second, by_passes: :passes).drift

    assert_equal 12, drift.pass
    assert_equal [:picture], drift.differed
    assert_equal first_frame(first, tape) { |game| game.var(:passes) == 12 }, drift.frame
    assert_equal first_frame(second, tape) { |game| game.var(:passes) == 12 }, drift.second_frame
    refute_equal drift.frame, drift.second_frame, "the late cartridge reaches pass 12 frames later"
  end

  def test_a_failure_says_the_pass
    error = assert_raises(Minitest::Assertion) do
      assert_plays_alike passing, passing(late: true, speck_on: 12), watch, by_passes: :passes
    end

    assert_match "pass 12", error.message
  end

  # Each pass is the first frame its cartridge shows it, so the moments say each one's frame.
  def test_the_moments_are_each_cartridges_own_frames
    result = walk.compare(passing, passing(late: true), by_passes: :passes)

    first, second = result.moments.fetch(:walked)
    assert_operator second, :>, first
  end

  # A count read as a byte comes round to nought, and is counted on past it.
  def test_a_count_that_wraps_is_counted_on_past_it
    eighths = ->(game) { game.var(:passes) % 8 }

    assert_plays_alike passing, passing(late: true), watch, by_passes: eighths, pass_count_wraps_at: 8
    drift = watch.compare(passing, passing(late: true, speck_on: 12), by_passes: eighths, pass_count_wraps_at: 8).drift
    assert_equal 12, drift.pass
  end

  def test_a_count_that_falls_with_no_wrap_said_is_refused
    error = assert_raises(VBlank::Playthroughs::Comparison::PassCountFell) do
      watch.compare(passing, passing(late: true), by_passes: ->(game) { game.var(:passes) % 8 })
    end

    assert_match "pass_count_wraps_at:", error.message
  end

  # The game loop's own count, which the framework keeps on a cartridge built here.
  def test_the_game_loops_own_count_lines_the_two_up
    assert_plays_alike passing, passing(late: true), watch, by_passes: true
  end

  # One way of reading the count for each cartridge, as `readings:` takes.
  def test_a_way_for_each_cartridge
    assert_plays_alike passing, passing(late: true), watch, by_passes: [:passes, ->(game) { game.var(:passes) }]
  end

  def test_a_second_cartridge_that_never_reaches_a_pass_is_an_error
    error = assert_raises(VBlank::Playthroughs::Comparison::PassNotReached) do
      watch.compare(passing, passing(stops_at: 10), by_passes: :passes)
    end

    assert_match "pass 11", error.message
  end

  # Two counts that never show the same pass compare nothing, which is not a pass.
  def test_counts_that_share_no_pass_are_an_error
    error = assert_raises(VBlank::Playthroughs::Comparison::PassNotReached) do
      watch.compare(passing, passing, by_passes: [:passes, ->(game) { game.var(:passes) + 1000 }])
    end

    assert_match "nothing was compared", error.message
  end

  def test_settings_that_need_frames_are_refused
    { forgiving_torn_frames_of: :second, reports_in: "drift", same: :script }.each do |setting, value|
      error = assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: :passes, setting => value) }

      assert_match "`by_passes:`", error.message, setting
    end
  end

  def test_a_wrap_with_no_count_and_a_count_that_is_no_way_are_refused
    assert_match "`by_passes:`", assert_raises(ArgumentError) { watch.compare(nil, nil, pass_count_wraps_at: 8) }.message
    assert_match "`by_passes:`", assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: 3) }.message
    assert_match "`pass_count_wraps_at:`",
                 assert_raises(ArgumentError) { watch.compare(nil, nil, by_passes: :passes, pass_count_wraps_at: 1) }.message
  end
end
