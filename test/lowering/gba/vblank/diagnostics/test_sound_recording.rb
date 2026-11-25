# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A recording of what a game sounds like, from the cartridge in the emulator, the desktop build or
# the Ruby lowering, kept as its samples: to write to a .wav and listen to, and to read frame by
# frame — how loud each frame is, and how many waves in it were broken, a voice jumping back to
# the start of its wave where the chip would carry on, which is heard as a rumble.
class TestSoundRecording < Minitest::Test
  # Recording the desktop build and the Ruby lowering starts their programs, which hangs inside a
  # Ractor.
  runs_on_the_main_ractor!

  SoundRecording = VBlank::Diagnostics::SoundRecording
  RATE = 48_000
  FRAME = RATE / 60

  # A square wave +period+ samples long, starting again from its first sample every +restart+.
  private def square(length, period:, restart: nil)
    Array.new(length) { |n| ((restart ? n % restart : n) % period) < period / 2 ? 1000 : -1000 }
  end

  def test_a_steady_tone_has_no_broken_waves
    recording = SoundRecording.new(samples: square(FRAME * 6, period: 109), rate: RATE, frame_seconds: 1r / 60)

    assert_equal [0] * 6, recording.frames.map(&:waves_broken)
  end

  # Started again at every frame, as a voice whose volume changes each frame is restarted: one
  # wave in each frame after the first is broken.
  def test_a_tone_started_again_every_frame_breaks_a_wave_a_frame
    recording = SoundRecording.new(samples: square(FRAME * 6, period: 109, restart: FRAME), rate: RATE, frame_seconds: 1r / 60)

    assert_equal [0, 1, 1, 1, 1, 1], recording.frames.map(&:waves_broken)
  end

  def test_each_frame_says_how_loud_it_is
    samples = square(FRAME, period: 109) + Array.new(FRAME, 0) + square(FRAME, period: 109).map { |s| s / 2 }
    recording = SoundRecording.new(samples: samples, rate: RATE, frame_seconds: 1r / 60)

    assert_equal [2000, 0, 1000], recording.frames.map(&:loudness)
  end

  # Each frame's loudest sample and biggest jump from one sample to the next: a click is a jump
  # far bigger than the tone's own edges.
  def test_each_frame_says_its_loudest_sample_and_biggest_jump
    samples = square(FRAME, period: 109) + Array.new(FRAME, 0).tap { |quiet| quiet[400] = 5000 }
    frames = SoundRecording.new(samples: samples, rate: RATE, frame_seconds: 1r / 60).frames

    assert_equal [1000, 5000], frames.map(&:loudest)
    assert_equal [2000, 5000], frames.map(&:biggest_jump)
  end

  # A held note recorded on each thing that plays it: heard on all three, the desktop build and the
  # game as Ruby sample for sample alike, and no wave broken on any.
  def test_a_held_note_is_recorded_on_the_cartridge_the_desktop_build_and_as_ruby
    builder = Builder.new
    builder.instance_eval do
      enable_sound
      song(:held) { note :A4, :whole }
      play_song :held
      game_loop {}
    end
    builder.finalize_program
    heard = %i[cartridge native ruby].to_h do |on|
      [on, SoundRecording.of(builder.program, on: on, frames: 20, only: :square1)]
    end

    assert_equal heard[:native].samples, heard[:ruby].samples
    heard.each do |on, recording|
      assert_operator recording.frames.map(&:loudness).max, :>, 0, "nothing was heard on #{on}"
      assert_equal 0, recording.frames.sum(&:waves_broken), "a wave was broken on #{on}"
    end
  end

  # Two recordings say where they first differ: a sample changed, one longer than the other, or
  # nowhere.
  def test_two_recordings_say_where_they_first_differ
    recording = ->(samples) { SoundRecording.new(samples: samples, rate: RATE, frame_seconds: 1r / 60) }

    assert_nil recording.call([1, 2, 3]).first_difference(recording.call([1, 2, 3]))
    assert_equal 1, recording.call([1, 2, 3]).first_difference(recording.call([1, 5, 3]))
    assert_equal 2, recording.call([1, 2]).first_difference(recording.call([1, 2, 3]))
  end

  # A .wav a person can open: one speaker, sixteen-bit samples, read back as they were written.
  def test_a_recording_writes_a_wav_that_reads_back_the_same
    recording = SoundRecording.new(samples: [0, 1000, -1000, 32_767, -32_768], rate: RATE, frame_seconds: 1r / 60)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "heard.wav")
      recording.write_wav(path)

      assert_equal recording.samples, SoundRecording.read_wav(path, frame_seconds: 1r / 60).samples
      assert_equal RATE, SoundRecording.read_wav(path, frame_seconds: 1r / 60).rate
    end
  end

  # A .wav of two speakers is heard as one, each moment the two halved; eight bits are widened to
  # sixteen; a chunk of words about the file before the sound is passed over.
  def test_a_wav_of_two_speakers_or_eight_bits_is_read_as_one_speaker
    Dir.mktmpdir do |dir|
      stereo = write_raw_wav(File.join(dir, "two.wav"), [100, 300, -200, 0].pack("s<*"), channels: 2, bits: 16, notes: true)
      eight = write_raw_wav(File.join(dir, "eight.wav"), [128, 255, 0].pack("C*"), channels: 1, bits: 8)

      assert_equal [200, -100], SoundRecording.read_wav(stereo, frame_seconds: 1r / 60).samples
      assert_equal [0, 127 << 8, -128 << 8], SoundRecording.read_wav(eight, frame_seconds: 1r / 60).samples
    end
  end

  def test_a_file_that_is_not_a_wav_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, "song.mp3")
      File.binwrite(path, "ID3 not a wave")

      assert_match "not a .wav file", assert_raises(ArgumentError) { SoundRecording.read_wav(path, frame_seconds: 1r / 60) }.message
    end
  end

  # Two recordings in one file for a person: one after the other with a moment's quiet between, or
  # the first on the left speaker and the second on the right, the one at the lower rate read at the
  # higher.
  def test_two_recordings_are_written_in_turn_or_side_by_side
    first = SoundRecording.new(samples: [1000, 2000], rate: 4, frame_seconds: 1r / 60)
    second = SoundRecording.new(samples: [-500], rate: 2, frame_seconds: 1r / 60)
    Dir.mktmpdir do |dir|
      in_turn = SoundRecording.write_pair(File.join(dir, "turn.wav"), first, second, layout: :in_turn)
      side = SoundRecording.write_pair(File.join(dir, "side.wav"), first, second, layout: :side_by_side)

      gap = [0] * (SoundRecording::PAIR_GAP_SECONDS * 4).round
      assert_equal [1000, 2000, *gap, -500, -500], SoundRecording.read_wav(in_turn, frame_seconds: 1r / 60).samples
      assert_equal [(1000 - 500) / 2, (2000 - 500) / 2], SoundRecording.read_wav(side, frame_seconds: 1r / 60).samples
      assert_equal 4, SoundRecording.read_wav(side, frame_seconds: 1r / 60).rate
      error = assert_raises(ArgumentError) { SoundRecording.write_pair(File.join(dir, "x.wav"), first, second, layout: :mixed) }
      assert_match "in_turn", error.message
    end
  end

  # A .wav of +data+ as another program writes it, with a chunk of words before the sound where +notes+.
  private def write_raw_wav(path, data, channels:, bits:, notes: false)
    format_chunk = ["fmt ", 16, 1, channels, RATE, RATE * channels * bits / 8, channels * bits / 8, bits].pack("a4VvvVVvv")
    list = notes ? ["LIST", 4, "INFO"].pack("a4Va4") : "".b
    body = "WAVE".b + format_chunk + list + ["data", data.bytesize].pack("a4V") + data
    File.binwrite(path, ["RIFF", body.bytesize].pack("a4V") + body)
    path
  end
end
