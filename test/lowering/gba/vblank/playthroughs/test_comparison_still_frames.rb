# frozen_string_literal: true

require "test_helper"
require "stringio"
require "comparison_games"

# EACH CARTRIDGE'S OWN STILL FRAMES SKIPPED (`skipping_still_frames_of:`). An original holds its
# picture still while it loads a room, for as many frames as that room takes; a port holds it for
# another number, or not at all. Frame by frame the two are out of step from the first load on.
# With the still frames of a side skipped, each frame whose picture changes is lined up with the
# other's frame that changes in turn, and the two come back into step after every load.
#
# The cartridges are one small game built with loads of different lengths: from tick LOAD_AT it
# draws nothing for +loading_for+ frames, and its world stands still meanwhile. Every other frame
# moves a marker, so every frame but a loading one has a picture of its own.
class TestComparisonStillFrames < Minitest::Test
  include ComparisonGames
  include VBlank::Testing::PlaysAlike

  LOAD_AT = 10
  CLOCK_Y = 150

  # +speck_on+ draws one white pixel on that step of the world alone. +ticking+ moves a dot in
  # the bottom corner on every frame, loading ones too: a clock.
  private def loading(loading_for: 0, speck_on: nil, ticking: false)
    VBlank.build("LOADING", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      ticks = var :ticks, 0
      world = var :world, 0
      x = var :x, 20
      game_loop do
        ticks += 1
        if ticks < LOAD_AT || ticks >= LOAD_AT + loading_for
          world += 1
          x += 2 if held(:right)
          clear_screen :blue
          draw_rect_at x, 60, 8, 8, :white
          draw_rect_at world % 200, 100, 4, 4, :green
          pixel 120, 130, :white if speck_on && world == speck_on
        end
        if ticking
          fill_rect 0, CLOCK_Y, 8, 1, :black
          draw_rect_at ticks % 8, CLOCK_Y, 1, 1, :white
        end
      end
    end
  end

  # A still title that starts the game a frame after START is pressed: the press is made on a
  # still frame, and the picture changes on the frame after it.
  private def title
    VBlank.build("TITLE", console: :gba, out: StringIO.new, err: StringIO.new) do
      screen :bitmap
      started = var :started, 0
      world = var :world, 0
      game_loop do
        if started == 1
          world += 1
          clear_screen :blue
          draw_rect_at world % 200, 100, 4, 4, :green
        else
          clear_screen :black
          started = 1 if pressed(:start)
        end
      end
    end
  end

  private def watch = VBlank.playthrough("watch") { wait frames: 50 }

  private def walk
    VBlank.playthrough "walk" do
      wait frames: 30
      hold :right, frames: 10
      wait frames: 10
    end
  end

  def test_loads_of_different_lengths_drift_frame_by_frame_and_not_with_still_frames_skipped
    short = loading(loading_for: 4)
    long = loading(loading_for: 11)

    assert_raises(Minitest::Assertion) { assert_plays_alike short, long, watch }
    assert_plays_alike short, long, watch, skipping_still_frames_of: :both
    assert_plays_alike long, short, walk, skipping_still_frames_of: :both, readings: { x: :x }
  end

  # A press made on a still frame reaches the second cartridge on its own still frames, in order,
  # so a title that waits for START starts on both.
  def test_a_press_on_a_still_frame_reaches_the_second
    press_start = VBlank.playthrough "press start" do
      wait frames: 10
      press :start
      wait frames: 30
    end

    result = press_start.compare(title, title, skipping_still_frames_of: :both, readings: { world: :world })
    refute result.drift?, result.drift.inspect
  end

  # A still frame is still in the part of the screen looked at: a clock left out does not make
  # every frame of a load move.
  def test_a_clock_left_out_does_not_keep_a_load_moving
    short = loading(loading_for: 4, ticking: true)
    long = loading(loading_for: 11, ticking: true)
    clock = [[0, CLOCK_Y, 8, 1]]

    assert_raises(Minitest::Assertion) { assert_plays_alike short, long, watch, skipping_still_frames_of: :both }
    assert_plays_alike short, long, watch, skipping_still_frames_of: :both, ignoring_rectangles: clock
  end

  # Only one side's still frames are skipped: the other is compared on every frame it shows.
  def test_one_side_alone_has_its_still_frames_skipped
    assert_plays_alike loading, loading(loading_for: 7), watch, skipping_still_frames_of: :second
    assert_raises(Minitest::Assertion) do
      assert_plays_alike loading, loading(loading_for: 7), watch, skipping_still_frames_of: :first
    end
  end

  def test_a_difference_after_a_load_is_found_on_each_cartridges_own_frame
    first = loading(loading_for: 4)
    second = loading(loading_for: 11, speck_on: 30)
    tape = watch.play(first).tape
    drift = watch.compare(first, second, skipping_still_frames_of: :both).drift

    assert_equal first_frame(first, tape) { |game| game.var(:world) == 30 }, drift.frame
    assert_equal first_frame(second, tape) { |game| game.var(:world) == 30 }, drift.second_frame
    assert_nil drift.pass
  end

  def test_a_failure_says_each_cartridges_frame
    error = assert_raises(Minitest::Assertion) do
      assert_plays_alike loading, loading(loading_for: 7, speck_on: 30), watch, skipping_still_frames_of: :second
    end

    assert_match(/frame \d+ of the first cartridge and frame \d+ of the second/, error.message)
  end

  def test_a_second_cartridge_whose_picture_never_changes_again_is_an_error
    error = assert_raises(VBlank::Playthroughs::Comparison::PictureStoodStill) do
      watch.compare(loading, loading(loading_for: 100_000), skipping_still_frames_of: :second)
    end

    assert_match "skipping_still_frames_of:", error.message
  end

  def test_a_side_that_is_none_of_the_three_and_settings_that_need_frames_are_refused
    assert_match "`skipping_still_frames_of:`",
                 assert_raises(ArgumentError) { watch.compare(nil, nil, skipping_still_frames_of: :ours) }.message
    { by_passes: :ticks, forgiving_torn_frames_of: :second, reports_in: "drift", same: :script }.each do |setting, value|
      error = assert_raises(ArgumentError) { watch.compare(nil, nil, skipping_still_frames_of: :both, setting => value) }

      assert_match "`skipping_still_frames_of:`", error.message, setting
    end
  end
end
