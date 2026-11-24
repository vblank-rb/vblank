# frozen_string_literal: true

require "test_helper"

# The pitch of a stretch of sound (Diagnostics::FramePitch), on waves made here whose pitch is known:
# two frames' worth at 44,100 samples a second, as a console's emulator hands them over.
class TestFramePitch < Minitest::Test
  FramePitch = VBlank::Diagnostics::FramePitch
  RATE = 44_100
  LENGTH = 1470 # two frames of 1/60 s

  private def square(hz, length: LENGTH, offset: 0) = Array.new(length) { |at| ((at * hz / RATE.to_f) % 1) < 0.5 ? 8000 + offset : -8000 + offset }
  private def sine(hz) = Array.new(LENGTH) { |at| (8000 * Math.sin(2 * Math::PI * hz * at / RATE)).round }
  private def cents(heard, hz) = 1200 * Math.log2(heard / hz)

  def test_a_square_wave_is_heard_at_its_pitch_within_a_few_cents
    [65.41, 220, 440, 523.25, 1046.5, 3520].each do |hz|
      assert_in_delta 0, cents(FramePitch.hertz_of(square(hz), rate: RATE), hz), 5, "a square at #{hz} Hz"
    end
  end

  # The emulator's output is not centred on nought: a wave off to one side has the same pitch.
  def test_a_wave_off_nought_is_heard_at_its_pitch
    assert_in_delta 0, cents(FramePitch.hertz_of(square(440, offset: 6000), rate: RATE), 440), 5
  end

  def test_a_sine_wave_is_heard_at_its_pitch
    assert_in_delta 0, cents(FramePitch.hertz_of(sine(330), rate: RATE), 330), 5
  end

  # A square wave is loud in its third and fifth harmonics; the first wave to match is the whole
  # one, not an octave below.
  def test_a_note_is_not_heard_an_octave_low
    assert_in_delta 440, FramePitch.hertz_of(square(440), rate: RATE), 3
  end

  # A frame's pitch is its own: the frame before is only room to look back into for a long wave.
  # So a note's first frame after silence has its pitch, and a new note is read on its first frame.
  def test_a_frame_is_heard_at_its_own_pitch_whatever_the_frame_before_held
    frame = LENGTH / 2

    assert_in_delta 0, cents(FramePitch.hertz_of(square(440, length: frame), rate: RATE, before: Array.new(frame, 0)), 440), 5
    assert_in_delta 0, cents(FramePitch.hertz_of(square(660, length: frame), rate: RATE, before: square(440, length: frame)), 660), 5
    before, held = square(65.41).each_slice(frame).to_a
    assert_in_delta 0, cents(FramePitch.hertz_of(held, rate: RATE, before: before), 65.41), 5,
                    "a wave longer than half a frame reaches back into the frame before"
  end

  # Above the top of a piano a wave is a few samples long, and not a whole number of them: such a
  # note is read at its own pitch, not at a lower one where a few of its waves line up.
  def test_a_very_high_note_is_not_read_lower
    [6000, 8000].each do |hz|
      assert_in_delta 0, cents(FramePitch.hertz_of(square(hz), rate: RATE), hz), 10, "a square at #{hz} Hz"
    end
  end

  def test_silence_and_noise_have_no_pitch
    random = Random.new(3)

    assert_nil FramePitch.hertz_of(Array.new(LENGTH, 0), rate: RATE)
    assert_nil FramePitch.hertz_of(Array.new(LENGTH) { random.rand(-8000..8000) }, rate: RATE)
  end

  def test_too_few_samples_have_no_pitch
    assert_nil FramePitch.hertz_of(square(440, length: 3), rate: RATE)
  end
end
