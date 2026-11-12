# frozen_string_literal: true

require VBlank.root.join("examples/pong").to_s
require VBlank.root.join("examples/jukebox").to_s

# THE SOUND A RUNTIME WRITTEN AGAIN MAKES, sample for sample: what would come out of the speaker,
# played by a lowering's runtime and by the native one's, which is already held to the cartridge in
# the emulator (test_native_tones.rb). The sound log and the mix are compared with the interpreter's
# on every frame by each checked run; what the voices make of them is held here. A lowering whose
# runtime is the native one's written again includes this and says which it is:
#
#   class TestJSSound < Minitest::Test
#     include RuntimeSounds
#     private def runtime_under_test = :js
#   end
#
# Each is recorded with Diagnostics::SoundRecording, and the two recordings say where they first
# differ.
module RuntimeSounds
  Native = VBlank::IR::Backends::Native

  # A waveform of the game's own: high for a quarter of its length, which no named shape is.
  THIN_PULSE = ([15] * 8 + [0] * 24).freeze

  SIDES = %i[left right].freeze # the speakers, each compared on its own

  def test_a_beep_sounds_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        beep 440, duty: :quarter, decay: :medium, volume: 15 if count == 4
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 70
  end

  # A song in two parts on the two square voices, coming round, with the music turned down and
  # faded out and back while a note is held, and a beep borrowing the second voice partway.
  def test_a_song_and_its_volume_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { duty :half; note :A4, :quarter; note :C5, :quarter; rest :quarter; note :E5, :quarter }
        voice(:bass) { duty :eighth; volume 8; note :A3, :half; note :E3, :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        beep 990, duty: :eighth, decay: :slow if count == 20
        music_volume 50 if count == 30
        fade_music_out frames: 20 if count == 60
        fade_music_in frames: 20 if count == 100
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 160
  end

  # Notes that fade and swell by themselves on the square and noise voices, one note saying its
  # own, with the music turned down while they sound: they are left to fade, and only the next
  # note of each part takes the new volume.
  def test_notes_that_fade_and_swell_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { decay :slow; note :A4, :half; note :C5, :half, decay: :fast }
        voice(:pad) { volume 0; swell :medium; note :E3, :whole }
        voice(:drums, plays: :noise) { note :C3, :quarter; note :C3, :quarter, swell: 2; rest :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        music_volume 50 if count == 30
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # Notes that slide their pitch by themselves on the first voice: a zap up that runs off the top,
  # a slow swoop down, a fine slide in the voice's own numbers and a note held still, with the music
  # turned down while they sound.
  def test_notes_that_slide_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) do
          slide_down :slow
          note :C5, :quarter, slide_up: :fast
          note :A5, :half
          note :E5, :quarter, slide_up: { every: 2, shift: 7 }
          note :G4, :quarter, slide_down: :none
        end
        voice(:bass) { note :C3, :whole }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        music_volume 50 if count == 40
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 160
  end

  # Notes that wobble their pitch on a square voice and the wave voice, one holding still, with the
  # music turned down while they wobble.
  def test_notes_that_wobble_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) do
          vibrato depth: 9, speed: 3, after: 6
          note :A4, :half
          note :C5, :quarter, vibrato: :none
          note :E5, :quarter
        end
        voice(:pad, plays: :wave) { vibrato depth: 6, speed: 5; note :E4, :whole }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        music_volume 50 if count == 40
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # Square notes in shapes of their own: one note's own, and a part stepping four a frame while
  # the music is turned down under it, then a beep on its voice.
  def test_notes_in_shapes_of_their_own_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { note :A4, :half; note :C5, :half, duty: :eighth }
        voice(:harmony) { duty %i[eighth quarter half three_quarter]; note :E4, :whole }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        music_volume 50 if count == 40
        beep 880, duty: :half, decay: :none, volume: 12 if count == 90
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # Parts on one speaker each, a note moving to the other side, the drums on both, and a beep that
  # takes the right-hand part's voice back to both.
  def test_parts_on_their_own_speakers_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { pan :left; note :A4, :half; note :C5, :half, pan: :right }
        voice(:bass) { pan :right; note :A3, :whole }
        voice(:pad, plays: :wave) { pan :left; note :E4, :whole }
        voice(:drums, plays: :noise) { note :C4, :quarter; note :C5, :quarter, pan: :left }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        beep 880, duty: :half, decay: :none, volume: 12 if count == 90
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # The wave voice told what to play at each loudness, then stopped; hits on the noise voice at
  # each of its pitches, plain and metallic. Each voice is heard on its own as well, the way a test
  # of one voice hears it.
  def test_the_wave_and_noise_voices_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        wave :triangle, :A4 if count == 4
        wave :triangle, :A4, volume: :half if count == 20
        wave THIN_PULSE, :C4, volume: :three_quarter if count == 36
        stop_wave if count == 52
        noise :explosion if count == 10
        noise pitch: :mid, decay: :medium, volume: 13, metallic: true if count == 50
        noise :zap if count == 90
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 140
    assert_sounds_like_the_native_runtime program, frames: 140, only: :wave
    assert_sounds_like_the_native_runtime program, frames: 140, only: :noise
  end

  # A pad on the wave voice and drums on the noise voice under a lead, the music volume reaching
  # both, and the pad left silent by `stop_wave` until the game's own `wave` switches the voice on.
  def test_a_songs_pad_and_drums_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      song :tune do
        tempo 120
        voice(:lead) { note :E5, :half; note :G5, :half }
        voice(:pad, plays: :sine) { volume 9; note :C3, :quarter; note :G3, :quarter; rest :quarter; note :C2, :quarter }
        voice(:drums, plays: :noise) { decay :slow; note :C3, :quarter; rest :quarter; note 4000, :quarter; note :C6, :quarter }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        music_volume 50 if count == 20
        fade_music_out frames: 30 if count == 70
        fade_music_in frames: 30 if count == 130
        stop_wave if count == 170
        wave THIN_PULSE, :A3, volume: :half if count == 200
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 250
  end

  # A sound effect over a tune on the wave voice: each note puts its own waveform in.
  def test_a_sound_effect_over_a_tune_sounds_as_on_the_native_runtime
    score = VBlank::Audio::Score
    tune = score.new(tempo: 150, parts: [score::Part.new(plays: :triangle, notes: (0..5).map do |n|
      score::Note.new(at: n * 20, key: :C4, length: 15)
    end)])
    hit = score.new(tempo: 150, priority: 68, parts: [score::Part.new(plays: THIN_PULSE, volume: 12, notes: [
      score::Note.new(at: 0, key: :E5), score::Note.new(at: 10, key: :G5, length: 8),
    ])])
    program = sound_program do
      enable_sound
      music = songs :music, [tune]
      sfx = sound_effects :sfx, { hit: hit }
      count = var :count, 0
      game_loop do
        count += 1
        music.play 0
        sfx.play :hit if count == 25
        wave :sawtooth, :A3, volume: :half if count == 70
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 130
  end

  # Recordings on the mixer, two at once and one looping, under a beep: the mixer's slice is in
  # every sample the speaker plays.
  def test_mixed_recordings_sound_as_on_the_native_runtime
    program = sound_program do
      enable_sound
      boom = sample :boom, pcm: [0, 60, 0, -60] * 400, rate: 8000
      hum = sample :hum, pcm: ([0, 30, 50, 30, 0, -30, -50, -30] * 50), rate: 16_000
      count = var :count, 0
      game_loop do
        count += 1
        boom.play if count == 3
        hum.play(loop: true) if count == 8
        beep 440, duty: :half, decay: :medium, volume: 12 if count == 12
      end
    end

    assert_sounds_like_the_native_runtime program, frames: 60
  end

  # Whole games. Pong: START, the zoom, and a rally long enough for its song to come round and the
  # ball to hit a wall and a paddle.
  def test_pongs_rally_sounds_as_on_the_native_runtime
    program = Native.new.checked_program(PongGame::GAME, err: nil)

    assert_sounds_like_the_native_runtime program, frames: 420, buttons: held(3..8 => [:a])
  end

  # The jukebox: a tune picked from its menu, played as recordings on the mixer, its two sound
  # effects over it, and its music faded out and in between two tunes.
  def test_the_jukeboxs_tunes_and_effects_sound_as_on_the_native_runtime
    program = Native.new.checked_program(Jukebox::GAME, err: nil)
    buttons = held(10..12 => [:down], 60..62 => [:a], 100..102 => [:b], 140..142 => [:down])

    assert_sounds_like_the_native_runtime program, frames: 220, buttons: buttons
  end

  private

  def sound_program(&block)
    builder = VBlank::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  # Runs of frames to the buttons held through them, as a frame number to its buttons.
  def held(runs) = runs.flat_map { |frames, buttons| frames.map { |frame| [frame, buttons] } }.to_h

  # Every sample of +frames+ frames, from each speaker, the same from both runtimes, and some of
  # them not silence. +only+ hears one voice (:square1, :square2, :wave, :noise).
  #
  # A program that names no console is played as the Advance and again as the PlayStation, whose
  # voices are its sound chip's, reading loops out of sound memory (runtime/rg_spu.c), and not the
  # Game Boy family's: each runtime keeps both, so both are held alike.
  def assert_sounds_like_the_native_runtime(program, frames:, only: nil, buttons: {})
    played_as = program.console ? [program] : [program, program.copy.tap { |copy| copy.console = :ps1 }]
    played_as.each do |each_program|
      SIDES.each do |side|
        native, under_test = [:native, runtime_under_test].map do |on|
          VBlank::Diagnostics::SoundRecording.of(each_program, on: on, frames: frames, buttons: buttons, only: only, side: side)
        end

        console = each_program.console || :gba
        refute native.samples.all?(&:zero?), "the native runtime made no sound on the #{side} as #{console}, so there is nothing to compare"
        first = native.first_difference(under_test)
        assert_nil first, "the two runtimes' sound on the #{side} as #{console} differs first at sample #{first} " \
                          "(#{native.samples.length} samples against #{under_test.samples.length})"
      end
    end
  end
end
