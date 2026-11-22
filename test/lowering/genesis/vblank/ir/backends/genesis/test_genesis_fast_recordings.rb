# frozen_string_literal: true

require "test_helper"
require "stringio"

# A recording read faster than its own rate: an instrument far above the note it was recorded at, or a
# recording made at a high rate. The sound processor reads each of its samples a step along the
# recording (Genesis::Runtime::Recordings#driver), and a step of several samples must sound as the
# interpreter mixes it: the waves of a square wave all one length, at the pitch the rate gives, and the
# whole heard as the game built as Ruby is heard (that build mixes as the interpreter does, and is held
# to it on every frame by its own run).
class TestGenesisFastRecordings < Minitest::Test
  include VBlank::Testing::HeardAlike

  # The emulator's sound runs at this many samples a second.
  SAMPLE_RATE = 44_100
  FRAMES = 90

  # How close the cartridge is held to the game built as Ruby. Measured on a recording read at its own
  # rate, which both play cleanly: the cartridge's DAC holds each sample where the Ruby build's mix
  # smooths it, which moves the tone by about 17 dB of the mel distance at worst and the rolloff by
  # under a thousand hertz, and the two keep the same loudness from moment to moment.
  HEARD_AS_RUBY = { quiet_below_db: 40, loudness_db_apart: 3, mel_db_apart: 20, noise_floor_db_apart: 12,
                    rolloff_hz_apart: 6_000 }.freeze

  # Fifteen samples up and fifteen down, at 39000 a second: 1300 waves a second, read about three
  # samples a step, more than the sound processor can copy ahead of itself.
  def test_a_recording_read_three_samples_a_step_sounds_as_the_interpreter
    assert_plays_as_the_interpreter(half: 15, rate: 39_000)
  end

  # The highest step a play can have: Recordings.z80_step holds a step under 256 samples, which a rate
  # of 3,400,000 a second comes just under. Fifteen thousand samples up and fifteen thousand down make
  # a wave long enough to hear at that rate: 113 a second.
  def test_a_recording_read_at_the_highest_step_sounds_as_the_interpreter
    step = VBlank::IR::Backends::Genesis::Runtime::Recordings.z80_step(3_400_000 * 65_536 / 13_000r, 13_000)

    assert_operator step, :>, 0xFF00, "the play's step is near the highest"
    assert_operator step, :<, 0xFFFF, "and not held at it"
    assert_plays_as_the_interpreter(half: 15_000, rate: 3_400_000)
  end

  private

  def assert_plays_as_the_interpreter(half:, rate:)
    clip = ([100] * half) + ([-100] * half)
    game = VBlank.game("FAST #{rate}", consoles: %i[genesis]) do
      enable_sound
      sample(:clip, pcm: clip, rate: rate).play(loop: true)
      game_loop { nil }
    end
    rom = game.build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
    wave = SAMPLE_RATE * 2 * half / rate.to_f
    gaps = wave_gaps(rom)

    refute_empty gaps, "the recording is heard"
    assert_in_delta wave, gaps.sum / gaps.size, wave / 100, "waves #{gaps.minmax.map { |gap| gap.round(1) }}, one is #{wave.round(1)}"
    assert_operator gaps.max, :<, wave * 1.25, "no wave is held long"
    assert_operator gaps.min, :>, wave * 0.75, "and none cut short"
    assert_sounds_like rom, heard_as_ruby(game), VBlank.playthrough("listen") { wait frames: FRAMES - SETTLING },
                       lead_in: VBlank.playthrough("settling") { wait frames: SETTLING }, **HEARD_AS_RUBY
  end

  # Genesis Plus GX's output is heard settling for a few frames after power-on, on any cartridge, so
  # both are heard from this many frames on.
  SETTLING = 10

  # The game built as Ruby, heard from SETTLING frames on.
  def heard_as_ruby(game)
    heard = VBlank::Diagnostics::SoundRecording.of(game.program(console: :genesis), on: :ruby, frames: FRAMES)
    settling = (SETTLING * heard.rate * heard.frame_seconds).floor
    VBlank::Diagnostics::SoundRecording.new(samples: heard.samples.drop(settling), rate: heard.rate,
                                            frame_seconds: heard.frame_seconds)
  end

  # The gaps between the cartridge's upward crossings of its sound's middle over its last second, in the
  # emulator's samples.
  def wave_gaps(rom)
    left = Dir.mktmpdir do |dir|
      path = File.join(dir, "fast.bin")
      rom.write(path)
      core = VBlank::Console.for(:genesis).open_core(path, save_dir: dir)
      Array.new(FRAMES) { core.run_frame.take_audio.each_slice(2).map(&:first) }.flatten.last(SAMPLE_RATE)
    ensure
      core&.destroy
    end
    middle = (left.max + left.min) / 2.0
    crossings = left.each_cons(2).with_index.filter_map do |(before, after), i|
      i + ((middle - before) / (after - before).to_f) if before < middle && after >= middle
    end
    crossings.each_cons(2).map { |before, after| after - before }
  end
end
