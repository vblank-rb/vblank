# frozen_string_literal: true

require "test_helper"

# What a comparison of two cartridges' heard sound measures, held on lists of loudest samples written
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

  # Every measure out is found at once, in the order they are checked: a run shows the whole picture.
  def test_every_measure_out_is_found_at_once
    early_loud = heard(0, 2000, 2000, 0, 0)
    late_quiet = heard(0, 0, 1000, 1000, 0)

    found = HeardComparison.between(early_loud, late_quiet, NONE_APART).differences

    assert_equal %i[first_heard level last_heard], found.map(&:what)
    assert_equal [2, 3], found.first.measured
  end

  # The level is held a stretch of frames at a time, where the game gives one: two songs whose average
  # is the same, one loud then quiet and the other quiet then loud, differ in their stretches.
  def test_the_level_is_held_a_stretch_of_frames_at_a_time
    loud_first = heard(1000, 1000, 500, 500)
    quiet_first = heard(500, 500, 1000, 1000)

    assert_nil difference(loud_first, quiet_first, level_share_apart: 0.1), "the averages are the same"
    found = difference(loud_first, quiet_first, level_share_apart: 0.1, level_stretch_frames: 2)

    assert_equal :level, found.what
    assert_equal 1..2, found.frames
    assert_equal [1000, 500], found.measured
    assert_equal 2, found.stretches_over
  end

  def test_a_stretch_of_no_frames_is_refused
    error = assert_raises(ArgumentError) { NONE_APART.with(level_stretch_frames: 0) }

    assert_match "level_stretch_frames", error.message
  end

  # The words of a failure name every measure out, and each level with how many times the other it is.
  def test_the_failure_words_name_every_measure_and_both_levels
    compared = HeardComparison.between(heard(0, 4000, 4000, 0, 0), heard(0, 0, 1000, 1000, 0), NONE_APART)

    words = VBlank::Testing::HeardAlike.difference_message(compared)

    assert_match "first heard on different frames", words
    assert_match "4000 on the first and 1000 on the second", words
    assert_match "the first is 4.0 times as loud as the second", words
    assert_match "last heard on different frames", words
  end

  # The speakers mixed are alike and each speaker alone is not: one speaker each, the other way round.
  # A measure out on a speaker that is out in the mix too is not said twice.
  def test_a_sound_on_the_other_speaker_is_a_difference_naming_the_speaker
    on_left = { left: heard(0, 1000, 0), right: heard(0, 0, 0) }
    on_right = { left: heard(0, 0, 0), right: heard(0, 1000, 0) }
    speakers = %i[left right].to_h { |speaker| [speaker, [on_left[speaker], on_right[speaker]]] }

    compared = HeardComparison.between(heard(0, 1000, 0), heard(0, 1000, 0), NONE_APART, speakers: speakers)

    assert_equal [%i[never_heard left], %i[never_heard right]], compared.differences.map { |found| [found.what, found.speaker] }
    louder = HeardComparison.between(heard(0, 2000, 0), heard(0, 1000, 0), NONE_APART,
                                     speakers: { left: [heard(0, 2000, 0), heard(0, 1000, 0)] })
    assert_equal [[:level, nil]], louder.differences.map { |found| [found.what, found.speaker] }
  end

  # A sound moved to line up with another keeps its length: what moves off one end is gone, and the
  # other end is silence.
  def test_a_sound_moved_earlier_or_later_keeps_its_length
    sound = heard(0, 0, 1000, 500, 0)

    assert_equal [1000, 500, 0, 0, 0], sound.moved(2).loudest_by_frame
    assert_equal [0, 0, 0, 0, 1000], sound.moved(-2).loudest_by_frame
    assert_equal [3, 1], [sound.first_heard, sound.moved(2).first_heard]
  end

  private def pitched(loudest, pitches) = HeardSound.new(loudest_by_frame: loudest, heard_above: 0, pitch_by_frame: pitches)

  # A frame both are heard on where one has a pitch and the other none (a noise, a drum, a wrong
  # instrument) is out, as a pitch too far apart is.
  def test_a_pitch_against_none_on_a_frame_both_are_heard_is_a_difference
    found = difference(pitched([1000, 1000, 1000], [440, 440, 440]), pitched([1000, 1000, 1000], [440, nil, nil]),
                       pitch_cents_apart: 25)

    assert_equal :pitch, found.what
    assert_equal 2, found.frame
    assert_equal [440, nil], found.measured
    assert_equal 2, found.frames_over
    assert_match "440.0 Hz on the first and no pitch on the second",
                 VBlank::Testing::HeardAlike.difference_message(HeardComparison.between(
                   pitched([1000, 1000, 1000], [440, 440, 440]), pitched([1000, 1000, 1000], [440, nil, nil]),
                   NONE_APART.with(pitch_cents_apart: 25)
                 ))
  end

  # Heard on both and pitched on neither: nothing was held, and the comparison says so.
  def test_no_pitch_on_either_side_is_said
    compared = HeardComparison.between(pitched([1000, 1000], [nil, nil]), pitched([1000, 1000], [nil, nil]),
                                       NONE_APART.with(pitch_cents_apart: 25))

    assert_predicate compared, :alike?
    assert_predicate compared, :pitch_unread
    refute_predicate HeardComparison.between(pitched([1000, 1000], [440, 440]), pitched([1000, 1000], [440, 440]),
                                             NONE_APART.with(pitch_cents_apart: 25)), :pitch_unread
  end

  # A move to line the two up is a start that many frames apart, so it is held to
  # first_heard_frames_apart: the difference names each one's first frame as played.
  def test_a_move_to_line_up_counts_against_the_first_frame_heard
    early = heard(0, 0, 1000, 500, 0, 0, 0)
    late = heard(0, 0, 0, 0, 1000, 500, 0)

    moved_too_far = HeardComparison.between(early, late, NONE_APART.with(line_up_within_frames: 3, first_heard_frames_apart: 1))
    allowed = HeardComparison.between(early, late, NONE_APART.with(line_up_within_frames: 3, first_heard_frames_apart: 2))

    assert_equal 2, moved_too_far.moved_frames
    assert_equal [[:first_heard, [3, 5]]], moved_too_far.differences.map { |found| [found.what, found.measured] }
    assert_predicate allowed, :alike?
    assert_equal 2, allowed.moved_frames
  end

  # Frames at or under heard_above are silence to the lining up: a hum under it does not pull the
  # two out of line.
  def test_lining_up_hears_nothing_at_or_under_the_silent_level
    hum = [490, 0] * 5
    first = HeardSound.new(loudest_by_frame: hum + [600, 600, 0, 0, 0, 0], heard_above: 500)
    second = HeardSound.new(loudest_by_frame: hum.rotate(1) + [600, 600, 0, 0, 0, 0], heard_above: 500)

    assert_equal 0, HeardComparison.between(first, second, NONE_APART.with(line_up_within_frames: 2, level_share_apart: 1)).moved_frames
  end

  # Moves as good as each other: the smaller, and of two as small, the second moved earlier.
  def test_a_tie_in_lining_up_takes_the_smaller_move_then_the_earlier
    compared = HeardComparison.between(heard(0, 0, 1000, 0, 0), heard(0, 1000, 0, 1000, 0),
                                       NONE_APART.with(line_up_within_frames: 1, first_heard_frames_apart: 1, level_share_apart: 1,
                                                       ending_frames_apart: 5))

    assert_equal 1, compared.moved_frames
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
