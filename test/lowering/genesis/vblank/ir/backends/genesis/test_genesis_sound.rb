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

  private

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
    left = run.sound_made.each_slice(2).map(&:first).last(SAMPLE_RATE / 6)
    middle = left.sum.fdiv(left.size)
    rises = left.each_cons(2).count { |before, after| before < middle && after >= middle }
    rises * SAMPLE_RATE.fdiv(left.size)
  end
end
