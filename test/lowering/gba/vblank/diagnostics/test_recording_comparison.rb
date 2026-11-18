# frozen_string_literal: true

require "test_helper"

# TWO RECORDINGS HELD TO EACH OTHER AS A PERSON HEARS THEM (Diagnostics::RecordingComparison), on
# recordings made here whose differences are known: a reference of sixteen bits at 44,100 a second,
# and ours made from the same notes at 22,050 a second and eight bits, as a port's cartridge plays a
# rendered song, then changed one way at a time.
#
# The notes are band-limited square waves (their odd harmonics up to HARMONICS_BELOW_HZ, each a third,
# a fifth ... as loud), so a recording at either rate holds the same sound and none folds back.
class TestRecordingComparison < Minitest::Test
  SoundRecording = VBlank::Diagnostics::SoundRecording
  RecordingComparison = VBlank::Diagnostics::RecordingComparison

  FRAME_SECONDS = 1r / 60
  HARMONICS_BELOW_HZ = 8000
  # Two notes and the rests after them, twice: [frequency, seconds], nil for a rest.
  TUNE = ([[440, 0.3], [nil, 0.2], [660, 0.3], [nil, 0.2]] * 2).freeze

  # What the comparison of a 22,050, eight-bit recording of the tune with the 44,100, sixteen-bit one
  # allows, each with its reason.
  ALLOWED = { quiet_below_db: 40,          # a sound 40 dB under the loudest is near silence
              loudness_db_apart: 3,        # 3 dB is a step a person just hears
              mel_db_apart: 6,             # eight bits round every band a little
              noise_floor_db_apart: 20,    # eight bits are noisier in the quiet than sixteen
              rolloff_hz_apart: 1500 }.freeze # the same notes stop at the same height, give or take a band

  private def tune(rate:, bits: 16, notes: TUNE, loudness: ->(_seconds) { 1.0 }, noise: 0, lead: 0)
    random = Random.new(1)
    samples = Array.new((lead * rate).round, 0.0)
    notes.each do |hz, seconds|
      Array.new((seconds * rate).round) do |at|
        time = samples.size.fdiv(rate)
        wave = hz ? (1..).step(2).take_while { |k| k * hz < HARMONICS_BELOW_HZ }.sum { |k| Math.sin(2 * Math::PI * k * hz * at / rate) / k } : 0
        samples << ((wave * 12_000 * loudness.call(time)) + (noise * ((random.rand * 2) - 1)))
      end
    end
    step = 1 << (16 - bits)
    SoundRecording.new(samples: samples.map { |sample| (sample / step).round.clamp(-32_768 / step, (32_767 / step)) * step },
                       rate: rate, frame_seconds: FRAME_SECONDS)
  end

  private def reference = @reference ||= tune(rate: 44_100)

  private def compared(ours, **changed) = RecordingComparison.between(ours, reference, **ALLOWED, **changed)

  private def outs(ours, **changed) = compared(ours, **changed).differences.map(&:what)

  def test_the_same_notes_at_a_lower_rate_and_eight_bits_are_heard_alike
    comparison = compared(tune(rate: 22_050, bits: 8))

    assert_predicate comparison, :alike?, comparison.differences.inspect
    assert_in_delta 0, comparison.measures.gain_db, 0.5
    assert_operator comparison.measures.worst_mel_db, :<, ALLOWED.fetch(:mel_db_apart)
  end

  def test_a_silent_start_is_passed_over
    assert_predicate compared(tune(rate: 22_050, bits: 8, lead: 0.5)), :alike?
  end

  def test_a_wrong_note_is_a_difference_of_tone_from_where_it_begins
    wrong = TUNE.map { |hz, seconds| [hz == 660 ? 990 : hz, seconds] }
    found = compared(tune(rate: 22_050, bits: 8, notes: wrong)).differences.find { |difference| difference.what == :tone }

    assert found, "a wrong note is heard"
    assert_in_delta 0.5, found.seconds, 2 * FRAME_SECONDS, "the second note begins half a second in"
    assert_equal (found.seconds / FRAME_SECONDS).round + 1, found.frame
  end

  def test_a_quieter_second_half_is_a_difference_of_loudness
    halved = ->(seconds) { seconds < 1.0 ? 1.0 : 0.4 }
    found = compared(tune(rate: 22_050, bits: 8, loudness: halved)).differences.find { |difference| difference.what == :loudness }

    assert found
    assert_operator found.seconds, :>=, 0.9
    ours, theirs = found.measured
    assert_operator theirs - ours, :>, ALLOWED.fetch(:loudness_db_apart)
  end

  def test_hiss_is_a_noise_floor_in_decibels
    found = compared(tune(rate: 22_050, noise: 2000)).differences.find { |difference| difference.what == :noise_floor }

    assert found
    ours, theirs = found.measured
    assert_operator ours - theirs, :>, ALLOWED.fetch(:noise_floor_db_apart)
    assert_in_delta(-120, theirs, 0.1, "the reference's rests are digital silence")
  end

  # Each sample the average of the ten around it: the highest harmonics are gone.
  def test_a_muffled_sound_stops_lower
    smoothed = tune(rate: 22_050).samples.each_cons(10).map { |run| run.sum / 10 }
    found = compared(SoundRecording.new(samples: smoothed, rate: 22_050, frame_seconds: FRAME_SECONDS))
            .differences.find { |difference| difference.what == :muffled }

    assert found
    ours, theirs = found.measured
    assert_operator theirs - ours, :>, ALLOWED.fetch(:rolloff_hz_apart)
  end

  # Every measure out is found at once.
  def test_every_measure_out_is_found_at_once
    wrong = TUNE.map { |hz, seconds| [hz == 660 ? 990 : hz, seconds] }

    found = outs(tune(rate: 22_050, notes: wrong, noise: 2000))

    assert_includes found, :tone
    assert_includes found, :noise_floor
  end

  def test_a_recording_never_heard_has_nothing_to_compare
    silent = SoundRecording.new(samples: Array.new(22_050, 0), rate: 22_050, frame_seconds: FRAME_SECONDS)

    assert_equal [:never_heard], outs(silent)
  end

  def test_a_tolerance_left_out_or_below_nought_is_refused
    assert_raises(ArgumentError) { RecordingComparison.between(reference, reference, quiet_below_db: 40) }
    error = assert_raises(ArgumentError) { RecordingComparison.between(reference, reference, **ALLOWED, mel_db_apart: -1) }

    assert_match "mel_db_apart", error.message
  end

  # The words a test fails with name every measure out and what was measured of both.
  def test_the_failure_words_name_each_measure_and_where
    wrong = TUNE.map { |hz, seconds| [hz == 660 ? 990 : hz, seconds] }
    words = VBlank::Testing::HeardAlike.recording_difference_message(compared(tune(rate: 22_050, notes: wrong, noise: 2000)))

    assert_match "The tone differs", words
    assert_match "more noise in the quiet", words
    assert_match(/first out \d+\.\d+ s from the first sound, on frame \d+/, words)
    assert_match "Measured, ours then the reference", words
  end
end
