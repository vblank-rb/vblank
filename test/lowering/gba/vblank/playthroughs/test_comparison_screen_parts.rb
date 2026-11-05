# frozen_string_literal: true

require "test_helper"
require "comparison_games"

# WHICH PART OF THE SCREEN A COMPARISON LOOKS AT, said four ways: a part to look within
# (`looking_at:`), a part on some stretches of frames only (a rectangle list for each stretch),
# a part a block works out on every frame from the two running cartridges (a part that moves with
# the scenery), and only every few pixels each way (`pixels_apart:`). The cartridges are the walker
# and the walker with specks, built here; where the specks are is known from ComparisonGames.
class TestComparisonScreenParts < Minitest::Test
  include ComparisonGames
  include VBlank::Testing::PlaysAlike

  SPECK = [SPECK_X, SPECK_Y, 3, 1].freeze

  def test_looking_within_a_part_leaves_out_everything_outside_it
    above_the_specks = [[0, 0, 240, SPECK_Y]]

    assert_plays_alike walker, walker(specks: 3), walk_right, looking_at: above_the_specks
    failure = assert_raises(Minitest::Assertion) do
      assert_plays_alike walker, walker(specks: 3), walk_right, looking_at: [[0, 0, 240, SPECK_Y + 1]]
    end
    assert_match "3 pixels differ", failure.message
  end

  def test_a_part_left_out_inside_a_part_looked_at_is_left_out
    assert_plays_alike walker, walker(specks: 3), walk_right, looking_at: [[0, 80, 240, 80]], ignoring_rectangles: [SPECK]
  end

  # The specks come up after the walk, so leaving them out from the moment :walked on is enough,
  # and leaving them out only before it is not.
  def test_a_part_left_out_on_a_stretch_of_frames_only
    assert_plays_alike walker, walker(specks: 3), walk_right, ignoring_rectangles: { (:walked..) => [SPECK] }

    failure = assert_raises(Minitest::Assertion) do
      assert_plays_alike walker, walker(specks: 3), walk_right, ignoring_rectangles: { (..:walked) => [SPECK] }
    end
    assert_match "3 pixels differ", failure.message
  end

  def test_a_part_looked_at_on_a_stretch_and_the_whole_screen_elsewhere
    assert_plays_alike walker, walker(specks: 3), walk_right, looking_at: { (:walked..) => [[0, 0, 240, 50]] }

    assert_raises(Minitest::Assertion) do
      assert_plays_alike walker, walker(specks: 3), walk_right, looking_at: { (..:walked) => [[0, 0, 240, 50]] }
    end
  end

  # A BLOCK CHOOSES THE PART ON EVERY FRAME, handed both running cartridges: here each box, which
  # the two walkers move at different speeds, is left out where its own game says it is. A part
  # that runs off the screen is cut to it rather than refused, since a part that moves with the
  # scenery slides off the edge.
  def test_a_part_chosen_on_each_frame_by_a_block
    boxes = ->(first, second) { [first, second].map { |game| [game.var(:x), 60, 8, 8] } << [-20, -20, 30, 30] }

    assert_plays_alike walker, walker(speed: 3), walk_right, ignoring_rectangles: boxes
    assert_raises(Minitest::Assertion) { assert_plays_alike walker, walker(speed: 3), walk_right }
  end

  # A block that takes three is handed the frame's number too, counted from 1: the specks come up
  # on tick SPECKS_FROM, which is no earlier than that frame.
  def test_a_block_of_three_is_handed_the_frame
    assert_plays_alike walker, walker(specks: 3), walk_right,
                       ignoring_rectangles: ->(_first, _second, frame) { frame >= SPECKS_FROM ? [SPECK] : [] }
    assert_raises(Minitest::Assertion) do
      assert_plays_alike walker, walker(specks: 3), walk_right, ignoring_rectangles: ->(_first, _second, frame) { frame >= 59 ? [SPECK] : [] }
    end
  end

  # The block is asked on every frame that is looked at, in order, so it can keep what it saw on
  # the frame before.
  def test_the_block_is_asked_on_every_frame_in_order
    asked = []
    walk_right.compare(walker, walker, looking_at: ->(first, _second) { (asked << first.var(:ticks)) && [[0, 0, 240, 160]] })

    assert_equal 60, asked.size, "once for each frame of the walk"
    assert_equal asked.sort, asked, "in the order they were played"
    assert_operator asked.last, :>, asked.first
  end

  def test_a_block_that_answers_no_list_of_rectangles_is_refused_saying_what_it_answered
    error = assert_raises(ArgumentError) { walk_right.compare(walker, walker, looking_at: ->(_first, _second) { 5 }) }

    assert_match "`looking_at:`", error.message
    assert_match "answered 5", error.message
  end

  # Every other pixel each way: the speck at an odd column is never looked at, and the one at an
  # even column is.
  def test_pixels_apart_looks_at_every_few_pixels_each_way
    even_speck_left_out = [[SPECK_X, SPECK_Y, 1, 1]]

    assert_plays_alike walker, walker(specks: 2), walk_right, ignoring_rectangles: even_speck_left_out, pixels_apart: 2
    assert_raises(Minitest::Assertion) do
      assert_plays_alike walker, walker(specks: 2), walk_right, ignoring_rectangles: even_speck_left_out
    end
    assert_raises(Minitest::Assertion) { assert_plays_alike walker, walker(specks: 2), walk_right, pixels_apart: 2 }
  end

  def test_settings_that_make_no_sense_are_refused_before_a_frame_is_played
    {
      { pixels_apart: 0 } => "`pixels_apart:`",
      { looking_at: [0, 0, 10, 10] } => "`looking_at:`",
      { looking_at: [[230, 0, 20, 10]] } => "off the screen",
      { ignoring_rectangles: { 1..10 => [0, 0, 10, 10] } } => "`ignoring_rectangles:`",
      { ignoring_rectangles: { :nowhere..:walked => [[0, 0, 10, 10]] } } => "no moment named :nowhere",
    }.each do |settings, phrase|
      error = assert_raises(ArgumentError, settings.inspect) { walk_right.compare(nil, nil, **settings) }
      assert_match phrase, error.message, settings.inspect
    end
  end

  # On the same script the two are compared at moments and not frame by frame, so a part that
  # changes with the frame means nothing there.
  def test_a_part_that_changes_with_the_frame_is_refused_on_the_same_script
    error = assert_raises(ArgumentError) do
      walk_right.compare(walker, walker, same: :script, ignoring_rectangles: ->(_first, _second) { [] })
    end

    assert_match "same script", error.message
  end

  def test_a_report_says_which_parts_were_looked_at
    Dir.mktmpdir do |folder|
      walk_right.compare(walker, walker(specks: 3), looking_at: [[0, 80, 240, 80]], pixels_apart: 2, reports_in: folder)
      text = File.read(Dir.glob(File.join(folder, "*", "report.txt")).first)

      assert_match "Only these parts of the screen were looked at: 240 by 80 pixels from column 0, row 80.", text
      assert_match "every 2nd pixel", text
    end
  end

  # A part of the screen worked out by a block is asked on every frame, those `ignoring_frames:`
  # leaves out too, so a block that keeps what it saw on the frame before is never stale.
  def test_a_part_block_is_asked_on_frames_left_out_too
    frames = []
    part = lambda do |_first, _second, frame|
      frames << frame
      [[0, 0, 240, 160]]
    end
    walk_right.compare(walker, walker, looking_at: part, ignoring_frames: [5..20])

    assert_equal (1..60).to_a, frames
  end
end
