# frozen_string_literal: true

require "test_helper"
require "brr_recordings"

# A RECORDING IN THE SUPER NINTENDO SOUND CHIP'S OWN FORMAT (Audio::SNESRecording), decoded as the
# chip decodes it, which is what the interpreter and every console but the Super Nintendo play. The
# answer key is the chip's decoder as fullsnes writes it (BRRRecordings.chip_samples), and a few
# samples worked out by hand in each test's comment. What bsnes makes of the same bytes is
# test/lowering/snes/vblank/ir/backends/snes/test_snes_brr_as_given.rb.
class TestSNESRecording < Minitest::Test
  SNESRecording = VBlank::Audio::SNESRecording

  private def pcm(recording) = recording.decoded.pcm.unpack("c*")

  # +decoded+ played for +count+ samples, reading round from where it holds.
  private def played(decoded, count)
    samples = decoded.pcm.unpack("c*")
    Array.new(count) do |at|
      at < samples.size ? samples[at] : samples[decoded.holds_from + ((at - decoded.holds_from) % (samples.size - decoded.holds_from))]
    end
  end

  def test_every_filter_decodes_as_the_chip_decodes_it
    recording = SNESRecording.new(bytes: BRRRecordings::LOUD)

    assert_equal BRRRecordings.chip_bytes(BRRRecordings::LOUD), pcm(recording)
    assert_nil recording.decoded.holds_from, "the last block ends the recording, and does not loop"
  end

  def test_filter_nought_shifts_each_sample_up_by_its_block
    # Shift 12: a nibble of 7 is 7 << 12 >> 1 = 14336, the byte 14336 >> 7 = 112; -8 is -16384, -128.
    assert_equal [112, -128, 16, 0], pcm(SNESRecording.new(bytes: BRRRecordings::LOUD)).first(4)
  end

  def test_filter_one_adds_fifteen_sixteenths_of_the_sample_before
    # Block 0 ends on 2048. Block 1, shift 8, starts on a nibble of 2: 2 << 8 >> 1 = 256, and the
    # guess 2048 + (-2048 >> 4) = 1920, so 2176, the byte 17. Its next nibble is 0: 2176 - 136 = 2040.
    decoded = BRRRecordings.chip_samples(BRRRecordings::LOUD)

    assert_equal [2176, 2040], decoded[16, 2]
    assert_equal [17, 15], pcm(SNESRecording.new(bytes: BRRRecordings::LOUD))[16, 2]
  end

  def test_a_shift_past_twelve_makes_minus_2048_or_nought
    # Block 3 is shift 13, filter 3: its first nibble, -1, is -2048 before the guess; the answer
    # key's guess from the two before (500, -578) is (-578 * 2) + (578 * 13 >> 6) - 500 + (1500 >> 4).
    old = -578
    older = 500
    guess = (old * 2) + ((-old * 13) >> 6) - older + ((older * 3) >> 4)

    assert_equal(-2048 + guess, BRRRecordings.chip_samples(BRRRecordings::LOUD)[48])
  end

  def test_a_sample_past_fifteen_bits_wraps_round_as_the_chip_does
    samples = BRRRecordings.chip_samples(BRRRecordings::LOUD)

    assert_equal [16_360, -1], samples[53, 2], "a guess past the top comes back from the bottom"
    assert_equal samples.map { |sample| sample >> 7 }, pcm(SNESRecording.new(bytes: BRRRecordings::LOUD))
  end

  def test_a_loop_that_starts_the_same_every_time_round_holds_from_its_loop_point
    recording = SNESRecording.new(bytes: BRRRecordings::QUIET, loop_at: BRRRecordings::QUIET_LOOP)
    decoded = recording.decoded

    assert_equal 32, decoded.holds_from, "two blocks before the loop point, sixteen samples each"
    assert_equal 64, decoded.pcm.bytesize
    assert_equal BRRRecordings.chip_samples(BRRRecordings::QUIET, loop_at: 18, loops: 20).map { |sample| sample >> 7 },
                 played(decoded, 64 + (20 * 32))
  end

  def test_a_loop_whose_times_round_take_turns_holds_round_all_of_them
    decoded = SNESRecording.new(bytes: BRRRecordings::TAKING_TURNS, loop_at: 18).decoded
    wanted = BRRRecordings.chip_bytes(BRRRecordings::TAKING_TURNS, loop_at: 18, loops: 40)

    assert_equal 5 * 32, decoded.pcm.bytesize - decoded.holds_from, "five times round the loop of 32"
    assert_equal wanted, played(decoded, wanted.size)
  end

  def test_a_loop_that_never_comes_back_to_where_it_started_holds_round_its_last_time
    looping = BRRRecordings::LOUD.dup.tap { |bytes| bytes[36] = 0x7F } # the last block loops to itself
    decoded = SNESRecording.new(bytes: looping, loop_at: 36).decoded

    assert_equal 64 + (SNESRecording::MOST_PASSES * 16), decoded.pcm.bytesize
    assert_equal 16, decoded.pcm.bytesize - decoded.holds_from
    assert_equal BRRRecordings.chip_bytes(looping, loop_at: 36, loops: SNESRecording::MOST_PASSES - 1),
                 decoded.pcm.unpack("c*")
  end

  def test_bytes_given_as_a_list_or_a_string_are_the_same_recording
    assert_equal SNESRecording.new(bytes: BRRRecordings::LOUD),
                 SNESRecording.new(bytes: BRRRecordings::LOUD.pack("C*"))
  end

  def test_part_of_a_block_is_refused
    error = assert_raises(ArgumentError) { SNESRecording.new(bytes: BRRRecordings::LOUD.first(40)) }

    assert_includes error.message, "blocks of 9 bytes"
  end

  def test_a_recording_no_block_ends_is_refused
    bytes = BRRRecordings::LOUD.dup
    bytes[36] = 0x7C
    error = assert_raises(ArgumentError) { SNESRecording.new(bytes: bytes) }

    assert_includes error.message, "end bit"
  end

  def test_blocks_after_the_end_are_refused
    error = assert_raises(ArgumentError) { SNESRecording.new(bytes: BRRRecordings::LOUD + BRRRecordings::LOUD.last(9)) }

    assert_includes error.message, "never plays them"
  end

  def test_a_loop_point_inside_a_block_is_refused
    error = assert_raises(ArgumentError) { SNESRecording.new(bytes: BRRRecordings::QUIET, loop_at: 20) }

    assert_includes error.message, "multiple of 9"
  end
end
