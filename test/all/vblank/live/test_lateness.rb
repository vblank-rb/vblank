# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# How many of a play's passes took longer than a frame, and how much of that was Ruby collecting
# garbage: the tally a live play keeps, and the line a person reads when it ends.
class TestLateness < Minitest::Test
  LatenessTally = VBlank::Live::LatenessTally

  FRAME = Rational(1, 60)

  def test_a_pass_within_its_frame_is_not_late
    tally = LatenessTally.new(frame_seconds: FRAME)
    tally.record(work_seconds: FRAME / 2, collection_seconds: 0)
    lateness = tally.lateness

    assert_equal [1, 0], [lateness.passes, lateness.late_passes]
    assert_match(/none ran longer than a frame/, lateness.words)
  end

  # Three passes: one on time, one late by half a frame with no collection in it, and one late by
  # a quarter of a frame that would have been on time without the half frame of collection in it.
  def test_late_passes_say_how_late_and_how_much_was_collection
    tally = LatenessTally.new(frame_seconds: FRAME)
    tally.record(work_seconds: FRAME / 2, collection_seconds: FRAME / 4)
    tally.record(work_seconds: FRAME * 3 / 2, collection_seconds: 0)
    tally.record(work_seconds: FRAME * 5 / 4, collection_seconds: FRAME / 2)
    lateness = tally.lateness

    assert_equal 3, lateness.passes
    assert_equal 2, lateness.late_passes
    assert_equal 1, lateness.late_because_of_collection
    assert_equal FRAME / 2, lateness.most_late_seconds
    assert_equal FRAME / 2, lateness.collection_seconds_in_late
  end

  # The line says which passes it counts, so it agrees with the count of pictures shown beside it:
  # every pass but the one the game set itself up in, and none played in fast forward.
  def test_the_words_say_which_passes_were_counted
    tally = LatenessTally.new(frame_seconds: FRAME)
    tally.record(work_seconds: FRAME * 2, collection_seconds: FRAME * 3 / 2)
    2.times { tally.record_fast_forward }

    words = tally.lateness.words
    assert_match(/Of the 1 passes after the one the game set itself up in, leaving out 2 played in fast forward/, words)
    assert_match(/garbage/, words)
    assert_match(/1 of them would have been on time/, words)
  end

  def test_a_collection_after_setup_is_said
    tally = LatenessTally.new(frame_seconds: FRAME)
    tally.record_setup_collection(Rational(1, 40))
    lateness = tally.lateness

    assert_equal Rational(1, 40), lateness.setup_collection_seconds
    assert_match(/after the game set itself up, in 25 ms/, lateness.words)
  end

  # What the play hands back is a finished value: counting more afterwards does not change it.
  def test_the_lateness_handed_back_does_not_change_afterwards
    tally = LatenessTally.new(frame_seconds: FRAME)
    lateness = tally.lateness
    tally.record(work_seconds: FRAME * 2, collection_seconds: 0)

    assert_equal 0, lateness.passes
    assert_predicate lateness, :frozen?
  end
end
