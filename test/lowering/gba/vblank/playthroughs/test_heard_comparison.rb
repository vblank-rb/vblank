# frozen_string_literal: true

require "test_helper"

# WHAT A COMPARISON OF TWO CARTRIDGES' HEARD SOUND MEASURES, held on lists of loudest samples written
# out here, so each measure is seen by itself: the cartridges in the emulator are
# test/heard_alike_tests.rb's. A note here is 1000 for as many frames as it is held.
class TestHeardComparison < Minitest::Test
  HeardSound = VBlank::Playthroughs::HeardSound
  HeardComparison = VBlank::Playthroughs::HeardComparison
  HeardTolerances = VBlank::Playthroughs::HeardTolerances
  FrameSound = VBlank::Diagnostics::FrameSound

  NONE_APART = HeardTolerances.new(first_heard_frames_apart: 0, level_share_apart: 0, ending_frames_apart: 0)

  private def heard(*loudest, above: 0) = HeardSound.new(loudest_by_frame: loudest, heard_above: above)

  private def difference(first, second, **changed)
    HeardComparison.between(first, second, NONE_APART.with(**changed)).difference
  end

  def test_a_frames_loudest_is_the_furthest_a_sample_is_from_nought_on_either_speaker
    sound = FrameSound.from_bytes([100, -300, 250, 20].pack("s<*"))

    assert_equal [100, -300, 250, 20], sound.samples
    assert_equal 300, sound.loudest
    assert_equal [[100, 250], [-300, 20]], [sound.left, sound.right]
    assert_equal 32_768, FrameSound.from_bytes([-32_768, 5].pack("s<*")).loudest
    assert_predicate FrameSound.from_bytes("".b), :silent?
  end

  def test_one_cartridges_measures_count_frames_from_one
    sound = heard(0, 0, 1000, 1000, 0, 1000, 400, 100, 0)

    assert_equal [3, 8], [sound.first_heard, sound.last_heard]
    assert_in_delta 3500 / 6.0, sound.level, 0.001, "the silent frame between two notes is counted"
    assert_equal 6, sound.fall_starts, "the last frame half as loud as the loudest"
    assert_equal 2, sound.fall_frames
  end

  def test_a_frame_is_heard_only_above_the_level_the_game_gives
    sound = heard(30, 30, 1000, 30, above: 50)

    assert_equal [3, 3], [sound.first_heard, sound.last_heard]
  end

  def test_two_alike_have_no_difference
    assert_predicate HeardComparison.between(heard(0, 1000, 0), heard(0, 1000, 0), NONE_APART), :alike?
  end

  def test_a_last_sound_that_falls_away_slower_is_named_from_where_the_fall_starts
    quick = heard(0, 1000, 1000, 400, 100, 0, 0)
    slow = heard(0, 1000, 400, 300, 100, 0, 0)

    found = difference(quick, slow, level_share_apart: 1)

    assert_equal :fall, found.what
    assert_equal [2, 3], found.measured
    assert_equal 3, found.frame, "the frame after the earlier one starts to fall"
    assert_equal [1000, 400], found.loudest
    assert_nil difference(quick, slow, level_share_apart: 1, ending_frames_apart: 1)
  end

  def test_a_level_within_the_share_of_the_louder_passes
    loud = heard(0, 1000, 1000, 0)
    quieter = heard(0, 900, 900, 0)

    assert_equal :level, difference(loud, quieter, level_share_apart: 0.05).what
    assert_equal [1000, 900], difference(loud, quieter, level_share_apart: 0.05).measured
    assert_nil difference(loud, quieter, level_share_apart: 0.1)
  end

  def test_neither_heard_is_a_difference_with_no_frame
    found = difference(heard(0, 0), heard(0, 0))

    assert_equal :never_heard, found.what
    assert_nil found.frame
  end

  def test_a_tape_of_passes_is_refused_before_anything_is_played
    tape = VBlank::Playthroughs::Tape.parse("vblank tape 1\nrecorded on: X 0x00000000\nstarts from: power-on\n" \
                                            "counts: passes\n\n10 -\n")

    error = assert_raises(ArgumentError) do
      HeardComparison.play(tape, "no.gba", "none.gba", heard_above: 0, **NONE_APART.to_h)
    end

    assert_match "counts passes", error.message
  end

  def test_presses_that_are_neither_a_tape_nor_a_playthrough_are_refused
    error = assert_raises(ArgumentError) { HeardComparison.play(300, "no.gba", "none.gba", heard_above: 0, **NONE_APART.to_h) }

    assert_match "tape", error.message
  end
end
