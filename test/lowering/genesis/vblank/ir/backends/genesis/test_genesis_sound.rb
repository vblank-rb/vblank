# frozen_string_literal: true

require "test_helper"

# Sound on a Genesis's two chips. Each game is played on the cartridge and the interpreter together
# (Genesis::CheckedRun), which holds the sound log to the interpreter's and each chip's registers to what
# the log says after every pass, so a write that never reaches a chip fails. What is measured here is what
# only the emulator's sound can say: that the chips made the note a game asked for.
class TestGenesisSound < Minitest::Test
  Genesis = VBlank::IR::Backends::Genesis

  # The emulator's sound runs at this many samples a second.
  SAMPLE_RATE = 44_100

  def test_a_beep_reaches_the_first_chip_at_its_pitch
    run = checked(frames: 4) do
      enable_sound
      beep 440, decay: :none, volume: 15
      game_loop { nil }
    end

    registers = run.chip_reads.last.last.first
    assert_equal Genesis::ChipWrites.tone_length(440), registers[Genesis::ChipWrites.psg_tone_register(1)]
    assert_equal 0, registers[Genesis::ChipWrites.psg_volume_register(1)]
  end

  def test_nothing_reaches_the_chips_before_enable_sound
    run = checked(frames: 4) do
      n = 0
      game_loop do
        n += 1
        enable_sound if n == 3
        beep 440, decay: :none, volume: 15 if n == 1
      end
    end

    assert_equal Genesis::ChipWrites::SILENT, run.chip_reads.last.last.first[Genesis::ChipWrites.psg_volume_register(1)]
  end

  def test_a_beep_is_heard_at_its_pitch
    assert_in_delta 440, pitch_heard { beep 440, decay: :none, volume: 15 }, 12
  end

  def test_a_beep_that_fades_goes_silent_by_itself
    run = checked(frames: 60) do
      enable_sound
      beep 440, decay: :fast, volume: 15
      game_loop { nil }
    end

    assert_equal Genesis::ChipWrites::SILENT, run.chip_reads.last.last.first[Genesis::ChipWrites.psg_volume_register(1)]
  end

  def test_a_noise_hit_reaches_the_noise_voice
    run = checked(frames: 4) do
      enable_sound
      noise :explosion
      game_loop { nil }
    end

    assert_equal Genesis::ChipWrites::NOISE_CLOCKED_BY_TONE | Genesis::ChipWrites::HISS,
                 run.chip_reads.last.last.first[Genesis::ChipWrites::PSG_NOISE_SETTING_REGISTER]
  end

  def test_a_wave_is_heard_at_its_pitch_on_the_fm_chip
    assert_in_delta 440, pitch_heard { wave :sine, 440 }, 12
  end

  def test_each_waveform_is_its_harmonics_on_four_operators
    sine = Genesis::ChipWrites.operator_levels(:sine)

    assert_equal 0, sine.first
    assert sine.drop(1).all? { |level| level > 40 }, "a sine has nothing past its first harmonic, not #{sine.inspect}"
  end

  def test_a_song_plays_its_notes_against_the_interpreter
    run = checked(frames: 40) do
      enable_sound
      song(:tune) do
        tempo 450
        voice(:lead) do
          note :A4, :quarter
          rest :quarter
        end
        voice(:bass) do
          volume 8
          note :A3, :half
        end
      end
      play_song :tune
      game_loop { nil }
    end

    assert_operator run.audio.count { |entry| entry.first == :note }, :>=, 2
  end

  # Thirty samples of a square wave, up then down.
  CLIP = (([100] * 15) + ([-100] * 15)).pack("c*")

  def test_a_recording_sounds_and_ends_with_the_interpreter
    run = recording_run(frames: 40, loop: false)

    assert_empty run.active_samples, "thirty samples are gone in a frame"
    assert_includes run.audio, [:sample, :clip]
  end

  def test_a_looping_recording_is_heard_through_the_sound_processor
    run = recording_run(frames: 20, loop: true)

    assert_equal [:clip], run.active_samples
    assert_operator run.loudest_each_frame.last, :>, 1000, "the sound processor is writing the recording to the FM chip"
  end

  def test_a_recording_is_heard_at_the_rate_it_was_recorded
    run = Genesis::HeadlessRun.new(keep_sound: true)
    run.run(recording_program(loop: true), frames: 20)

    # Fifteen samples up and fifteen down at 13000 a second is 433 waves a second.
    assert_in_delta 433, pitch_of(run), 25
  end

  private

  def recording_program(loop:)
    build = VBlank::IR::Build
    program = build.program(build.enable_sound, build.sample(:clip, CLIP, 13_000), build.play_sample(:clip, loop: loop),
                            build.loop_(build.wait_vblank))
    program.console = :genesis
    program
  end

  def recording_run(frames:, loop:) = Genesis::CheckedRun.new.run(recording_program(loop: loop), frames: frames)

  def program_of(&game)
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen :tiled
      instance_eval(&game)
    end
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
  end

  def checked(frames:, &game) = Genesis::CheckedRun.new.run(program_of(&game), frames: frames)

  # The strongest pitch of the sound a game makes after its first few frames, in Hz: the frequency whose
  # waves line up best with the sound, found by counting where it crosses nought going up.
  def pitch_heard(&sounds)
    run = Genesis::HeadlessRun.new(keep_sound: true)
    run.run(program_of do
      enable_sound
      instance_eval(&sounds)
      game_loop { nil }
    end, frames: 20)
    pitch_of(run)
  end

  def pitch_of(run)
    left = run.sound_made.each_slice(2).map(&:first).last(SAMPLE_RATE / 6)
    middle = left.sum.fdiv(left.size)
    rises = left.each_cons(2).count { |before, after| before < middle && after >= middle }
    rises * SAMPLE_RATE.fdiv(left.size)
  end
end
