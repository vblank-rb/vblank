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

  # THE SOUND PROCESSOR IS STOPPED WHILE THE VIDEO CHIP COPIES A BLOCK, and while the 68000 writes
  # into its memory. A recording has to keep its pitch through that, so these hold it far closer
  # than the test above, by where the sound crosses its middle and not by a count.
  def test_a_recording_alone_keeps_its_pitch
    assert_in_delta RECORDED_HZ, pitch_while { game_loop { nil } }, 2
  end

  # A long recording is read with a different end in sight for most of its length than a short one.
  def test_a_long_recording_keeps_its_pitch
    assert_in_delta RECORDED_HZ, pitch_while(clip: CLIP * 100) { game_loop { nil } }, 2
  end

  # A RECORDING LONGER THAN THE SOUND PROCESSOR'S WINDOW ONTO THE CARTRIDGE (32K) is read through more
  # than one bank of it, and goes round from the bank it ends on to the one it starts on. Heard over
  # most of three seconds, which takes in both.
  def test_a_recording_across_two_banks_keeps_its_pitch_as_it_goes_round
    clip = CLIP * 1100
    heard = waves_while(clip: clip, frames: 180, seconds: 2.8) { game_loop { nil } }

    assert_operator clip.bytesize, :>, Genesis::Runtime::Recordings::WINDOW
    assert_in_delta RECORDED_HZ, pitch_of_waves(heard), 2
    assert_operator longest_wave(heard), :<, WAVE_SAMPLES * 1.25, "every wave is heard, the bank's change and the loop's too"
  end

  # A SONG'S NOTES are written to the FM chip by the sound processor itself, between two samples, so a
  # note does not hold the recording still. Under a wave part playing a note every two frames every
  # wave of the recording is heard, and at its pitch: a wave lost would be a gap twice as long.
  def test_a_recording_keeps_every_wave_under_a_song_playing_a_note_every_two_frames
    heard = waves_while do
      song(:tune) do
        tempo 900
        voice(:pad, plays: :wave) { 8.times { note :A3, :eighth; note :C4, :eighth } }
      end
      play_song :tune
      game_loop { nil }
    end

    assert_in_delta RECORDED_HZ, pitch_of_waves(heard), 2
    assert_operator longest_wave(heard), :<, WAVE_SAMPLES * 1.25, "no wave of the recording is lost under the song"
  end

  # THE TIMERS' REGISTER ALSO HOLDS THE THIRD FM VOICE'S MODE, and the sound processor writes it every
  # sample. A mode the game sets is written into the value of each of those writes, so every write of
  # the register in the sound processor's program must be one the 68000 knows to change.
  def test_every_write_of_the_timers_register_carries_the_third_voices_mode
    recordings = Genesis::Runtime::Recordings
    program = recordings.driver
    code = program.code
    loads = (0...code.size - 2).select { |at| code[at] == 0x21 && code[at + 2] == recordings::TIMERS }.map { |at| at + 1 }
    named = (0...code.size - 5).select { |at| code[at, 3] == [0x3E, recordings::TIMERS, 0x77] }.map { |at| at + 4 }
    patched = recordings::TIMER_WRITES.keys.map { |label| program.address_of(label) }

    assert_equal (loads + named).sort, patched.sort
    recordings::TIMER_WRITES.each do |label, value|
      assert_equal value, code[program.address_of(label)], "#{label} holds the timers' own bits, with no mode"
    end
  end

  # A PAL CONSOLE's sound chip runs a little slower, so its timer's ticks come further apart and the
  # sound processor steps through a recording a little further at each. Genesis Plus GX plays a
  # cartridge whose header names Europe alone as a PAL console.
  def test_a_recording_keeps_its_pitch_on_a_pal_console
    rom = VBlank.build("PAL PITCH", console: :genesis, out: StringIO.new, err: StringIO.new) do
      enable_sound
      sample(:clip, pcm: CLIP.unpack("c*"), rate: 13_000).play(loop: true)
      game_loop { nil }
    end
    left = Dir.mktmpdir do |dir|
      path = File.join(dir, "pal.bin")
      rom.write(path)
      bytes = File.binread(path)
      bytes[VBlank::Console::GenesisHardware::REGION_AT, 3] = "E  "
      File.binwrite(path, bytes)
      core = VBlank::Console.for(:genesis).open_core(path, save_dir: dir)
      Array.new(100) { core.run_frame.take_audio.each_slice(2).map(&:first) }.flatten
    ensure
      core&.destroy
    end

    assert_operator left.size / 100, :>, SAMPLE_RATE / 55, "the console runs as a PAL one, fifty frames a second"
    assert_in_delta RECORDED_HZ, pitch_of_waves(crossings_of(left.last(SAMPLE_RATE / 2))), 2
  end

  # A RECORDED PART SET TO ONE SIDE is heard from both speakers alike: the FM chip's sixth voice plays
  # every recording, and it plays from both.
  def test_a_recorded_part_set_to_one_side_is_heard_from_both_speakers
    run = Genesis::HeadlessRun.new(keep_sound: true)
    clip = CLIP
    run.run(program_of do
      enable_sound
      instrument :clip, pcm: clip.unpack("c*") * 100, rate: 13_000, note: :C4
      song(:tune) do
        tempo 150
        voice(:keys, plays: :clip) { |v| v.pan :left; v.note :C4, :whole }
      end
      play_song :tune
      game_loop { nil }
    end, frames: 20)
    left, right = run.sound_made.last(SAMPLE_RATE / 6 * 2).each_slice(2).to_a.transpose.map { |side| side.max - side.min }

    assert_operator left, :>, 1000, "the recording is heard"
    assert_in_delta 1.0, left.fdiv(right), 0.05, "as loud from the right (#{left}, #{right})"
  end

  def test_a_recording_played_once_leaves_the_speaker_still
    run = Genesis::HeadlessRun.new(keep_sound: true)
    run.run(recording_program(loop: false), frames: 40)
    left = run.sound_made.each_slice(2).map(&:first).last(SAMPLE_RATE / 6)

    assert_operator left.max - left.min, :<, 200, "the recording is over, and the sound processor has stopped writing it"
  end

  def test_a_recording_keeps_its_pitch_while_eighty_sprites_move
    heard = pitch_while do
      image(:dot, "#" => :red) { Array.new(8, "########").join("\n") }
      things = Array.new(80) { |i| sprite :dot, at: [8 + ((i % 16) * 16), 8 + ((i / 16) * 20)] }
      t = var :t, 0
      game_loop do
        t += 1
        things.each_with_index { |thing, i| thing.move_to 8 + ((i % 16) * 16) + (t & 7), 8 + ((i / 16) * 20) }
      end
    end

    assert_in_delta RECORDED_HZ, heard, 2
  end

  def test_a_recording_keeps_its_pitch_while_a_painted_screen_sends_tiles_every_pass
    heard = pitch_while(:bitmap) do
      game_loop { 16.times { |k| fill_rect 8 + (k * 16), 100, 8, 8, :red } }
    end

    assert_in_delta RECORDED_HZ, heard, 2
  end

  private

  # CLIP at 13000 samples a second: fifteen up and fifteen down.
  RECORDED_HZ = 13_000 / 30.0
  # One wave of it, in the emulator's samples.
  WAVE_SAMPLES = SAMPLE_RATE / RECORDED_HZ

  # The pitch +clip+ is heard at, looping, in a game that also does +game+ on a +kind+ of screen:
  # the waves between the first upward crossing of the middle and the last, over the last third
  # of a second.
  def pitch_while(kind = :tiled, clip: CLIP, &game) = pitch_of_waves(waves_while(kind, clip: clip, &game))

  # Where +clip+, looping in that game, crosses its middle going up, in the emulator's samples, over
  # the last +seconds+ of +frames+.
  def waves_while(kind = :tiled, clip: CLIP, frames: 60, seconds: 1 / 3r, &game)
    clip = clip.unpack("c*")
    builder = VBlank::Builder.new
    builder.instance_eval do
      screen kind
      enable_sound
      sample(:clip, pcm: clip, rate: 13_000).play(loop: true)
      instance_eval(&game)
    end
    builder.finalize_program
    run = Genesis::HeadlessRun.new(keep_sound: true)
    run.run(builder.program.copy.tap { |program| program.console = :genesis }, frames: frames)
    crossings_of(run.sound_made.each_slice(2).map(&:first).last((SAMPLE_RATE * seconds).to_i))
  end

  # Each upward crossing of the sound's middle, placed between its two samples.
  def crossings_of(left)
    middle = (left.max + left.min) / 2.0
    crossings = []
    left.each_cons(2).with_index do |(before, after), i|
      crossings << (i + ((middle - before) / (after - before).to_f)) if before < middle && after >= middle
    end
    crossings
  end

  # Every wave counted from the first crossing to the last. A wave held still or lost makes it low.
  def pitch_of_waves(crossings) = (crossings.length - 1) * SAMPLE_RATE / (crossings.last - crossings.first)

  # The longest gap between two crossings, in the emulator's samples: a wave lost shows as twice one.
  def longest_wave(crossings) = crossings.each_cons(2).map { |before, after| after - before }.max

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
