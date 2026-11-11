# frozen_string_literal: true

require "test_helper"

# Sound on a PlayStation's sound chip. Each game is played in Beetle PSX and on the interpreter together
# (PS1::CheckedRun), which holds the sound log to the interpreter's and the chip's registers to what the
# log says after every pass, so a write that never reaches the chip fails. What is measured here is what
# only the emulator's sound can say: that the chip made the note a game asked for.
class TestPS1Sound < Minitest::Test
  PS1 = VBlank::IR::Backends::PS1
  SPU = PS1::SPUWrites
  H = VBlank::Console::PS1Hardware

  # The emulator's sound runs at this many samples a second.
  SAMPLE_RATE = 44_100

  def test_a_beep_reaches_the_first_voice_at_its_pitch_and_loudness
    run = checked(frames: 4) do
      enable_sound
      beep 440, decay: :none, volume: 15
      game_loop { nil }
    end

    registers = run.spu_reads.last.last
    assert_equal SPU.square_pitch(440), registers[SPU.register(SPU::BEEP_VOICE, H::SPU_PITCH)]
    assert_equal SPU::LOUDEST, registers[SPU.register(SPU::BEEP_VOICE, H::SPU_VOLUME_LEFT)]
  end

  def test_nothing_reaches_the_chip_before_enable_sound
    run = checked(frames: 4) do
      n = 0
      game_loop do
        n += 1
        enable_sound if n == 3
        beep 440, decay: :none, volume: 15 if n == 1
      end
    end

    assert_equal 0, run.spu_reads.last.last[SPU.register(SPU::BEEP_VOICE, H::SPU_PITCH)]
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

    assert_equal 0, run.spu_reads.last.last[SPU.register(SPU::BEEP_VOICE, H::SPU_VOLUME_LEFT)]
    assert_operator run.loudest_each_frame.last(10).max, :<, 50, "the beep has faded away"
  end

  def test_a_noise_hit_is_heard_and_a_metallic_one_plays_the_rattle
    run = checked(frames: 6) do
      enable_sound
      noise :hat
      game_loop { nil }
    end

    memory = run.rom.built.sound_voicing.memory
    assert_equal memory.start_of(:rattle), run.spu_reads.last.last[SPU.register(SPU::NOISE_VOICE, H::SPU_START)]
    assert_operator run.loudest_each_frame.max, :>, 1000
  end

  def test_a_wave_is_heard_at_its_pitch
    assert_in_delta 440, pitch_heard { wave :sine, 440 }, 12
  end

  def test_stop_wave_lets_the_wave_voice_go
    run = checked(frames: 20) do
      enable_sound
      n = 0
      wave :triangle, 440
      game_loop do
        n += 1
        stop_wave if n == 5
      end
    end

    assert_operator run.loudest_each_frame.last(5).max, :<, 50
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

  def test_a_song_is_heard_at_its_notes_pitch
    assert_in_delta 440, pitch_heard {
      song(:tune) do
        tempo 60
        voice(:lead) { note :A4, :whole }
      end
      play_song :tune
    }, 12
  end

  def test_a_tune_stopped_lets_its_voices_go
    run = checked(frames: 30) do
      enable_sound
      song(:tune) do
        tempo 120
        voice(:lead) { note :A4, :whole }
      end
      n = 0
      play_song :tune
      game_loop do
        n += 1
        stop_music if n == 10
      end
    end

    assert_operator run.loudest_each_frame.last(5).max, :<, 50
  end

  def test_each_loop_reads_back_from_its_blocks_exactly
    square = PS1::SoundMemory.square_samples(2)
    wave = PS1::SoundMemory.wave_samples(VBlank::Audio::Sound.wavetable(:sine))

    assert_equal square, PS1::ADPCM.decode(PS1::ADPCM.encode(square, loop: true))
    assert_equal wave, PS1::ADPCM.decode(PS1::ADPCM.encode(wave, loop: true))
  end

  def test_a_recording_comes_back_within_a_step_of_its_shift
    samples = Array.new(56) { |i| (Math.sin(i / 4.0) * 20_000).round }
    decoded = PS1::ADPCM.decode(PS1::ADPCM.encode(samples, loop: false)).take(samples.size)

    samples.zip(decoded).each { |want, got| assert_in_delta want, got, 2048 }
  end

  private

  def program_of(&game)
    builder = Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end

  def checked(frames:, &game) = PS1::CheckedRun.new.run(program_of(&game), frames: frames)

  # The strongest pitch of the sound a game makes after its first few frames, in Hz, found by counting where
  # the left speaker's sound crosses its middle going up.
  def pitch_heard(&sounds)
    run = PS1::HeadlessRun.new(keep_sound: true)
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
