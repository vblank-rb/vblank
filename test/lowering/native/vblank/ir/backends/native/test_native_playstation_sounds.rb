# frozen_string_literal: true

require "test_helper"

# THE DESKTOP BUILD MADE AS THE PLAYSTATION SOUNDS LIKE THE PLAYSTATION PROGRAM: the C build's speaker
# against the program played in Beetle PSX, frame by frame. The desktop build plays the game's voices the
# way the PlayStation's sound chip does (runtime/rg_spu.c: the same loops, read at the same pitch, through
# the same envelope, interpolation and volumes), so the two are held close: each frame as loud, each held
# note at the same pitch, each hiss as bright.
#
# HOW THE TWO ARE SET SIDE BY SIDE. Beetle hands its sound over at the chip's own 44100 samples a second,
# three quarters as loud as the chip makes it (spu.c, "75% attenuation for resampling headroom"); the
# desktop build's is at 48000, each of its samples holding the chip's newest. So a frame is read from each
# at its own rate, and Beetle's loudness taken back up by four thirds. A frame's loudness is how much
# sound it holds (the root of its samples' mean square), which two voices heard together give the same
# however their waves lie against each other. The program in Beetle starts a frame or two after the
# desktop build, so the runs are lined up on the frame each is first heard in, tried a frame either way,
# keeping the best.
#
# Each program plays one voice at a time. Beetle cannot leave a voice out of its mix, and where two
# voices sound together how their waves lie against each other is decided by where in a frame the
# program wrote each, which the desktop build does not keep.
#
# WHAT BEETLE DOES THAT THE DESKTOP BUILD DOES NOT: the first time a voice is started in a run, it is
# heard a frame later than every time after (a voice struck at pass 30 and again every 30 passes is heard
# a frame short of 30 apart the first time, and 30 after, unless a silent note struck it before). Nothing
# in the program's writes says why, so the desktop build does not copy it: a test whose first sound is the
# game's own strikes its voice silently first, and a frame here is held to Beetle's frame before it, the
# same frame and the frame after.
#
# THE TOLERANCES, measured on the programs below (the commit that made this says by how much): a square
# or wave voice's frame came within half of LOUDNESS_SLACK of Beetle's, and a hiss's within it, since a
# frame of a hiss holds a different stretch of its pattern on each; a held note's pitch within half of
# PITCH_SLACK, which is what reading a square wave's edges at two sample rates leaves; and a hiss's rises
# exactly. They are tight on purpose: a voice a step of volume out, or a pitch a few cents out, fails.
class TestNativePlaystationSounds < Minitest::Test
  Native = VBlank::IR::Backends::Native
  PS1 = VBlank::IR::Backends::PS1

  BEETLE_RATE = 44_100
  NATIVE_RATE = Native::HeadlessRun::SOUND_RATE
  FRAME_SECONDS = VBlank::Console.described(:ps1).frame_seconds
  BEETLE_LOUDNESS = Rational(4, 3) # Beetle's sound is three quarters of the chip's

  FULL_LOUDNESS = 7137        # a square voice at volume 15, as the chip makes it, whatever its width
  LOUDNESS_SLACK = 0.01       # as a share of FULL_LOUDNESS: under a seventh of a step of volume
  PITCH_SLACK = 0.002         # as a share of the pitch: three cents
  RISES_SLACK = 0.05          # as a share of how often the sound rises through nought in three frames
  HEARD = 0.05                # a frame at least this share of FULL_LOUDNESS is heard
  STEADY = 0.03               # waves this near their mean length are one note
  MOST_FRAMES_APART = 3
  EDGE_SAMPLES = 8            # left out at each end of a frame (#frames_of)

  # One frame of one speaker: how loud it is, and when it rises through nought, in seconds from the
  # run's start.
  Frame = Data.define(:loudness, :rises)

  def test_a_beep_fades_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 90) do
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        beep 220, decay: :none, volume: 0 if count == 2 # Beetle starts a voice late the first time (see above)
        beep 440, duty: :quarter, decay: :medium, volume: 15 if count == 4
        beep 990, duty: :eighth, decay: :slow, volume: 12 if count == 40
      end
    end
  end

  def test_the_wave_voice_sounds_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 90) do
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        wave :triangle, :A4 if count == 4
        wave :sine, :C4, volume: :half if count == 30
        wave :sawtooth, :E5, volume: :three_quarter if count == 50
        stop_wave if count == 75
      end
    end
  end

  def test_noise_hits_sound_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 120, hiss: true) do
      enable_sound
      count = var :count, 0
      game_loop do
        count += 1
        noise pitch: :mid, decay: :none, volume: 0 if count == 2 # (see above)
        noise :explosion if count == 4
        noise pitch: :mid, decay: :medium, volume: 13, metallic: true if count == 60
      end
    end
  end

  # A tune of one part with a rest, the music turned down, and faded out and back while a note is held.
  def test_a_tune_and_its_volume_sound_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 160) do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { duty :half; note :A4, :quarter; note :C5, :quarter; rest :quarter; note :E5, :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        music_volume 50 if count == 30
        fade_music_out frames: 20 if count == 60
        fade_music_in frames: 20 if count == 100
      end
    end
  end

  # A tune's part on the second square voice, and a beep borrowing that voice partway through a note.
  def test_a_beep_over_a_tunes_part_sounds_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 110) do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { rest :whole }
        voice(:bass) { duty :eighth; volume 8; note :A3, :half; note :E3, :half }
      end
      count = var :count, 0
      play_song :tune
      game_loop do
        count += 1
        beep 990, duty: :quarter, decay: :slow if count == 20
      end
    end
  end

  # Notes that fade by themselves, one fast.
  def test_notes_that_fade_sound_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 130) do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { decay :slow; note :A4, :half; note :C5, :half, decay: :fast }
      end
      play_song :tune
      game_loop {}
    end
  end

  # A pad on the wave voice with a rest.
  def test_a_pad_on_the_wave_voice_sounds_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 130) do
      enable_sound
      song :tune do
        tempo 120
        voice(:pad, plays: :sine) { volume 9; note :C3, :quarter; note :G3, :quarter; rest :quarter; note :C4, :quarter }
      end
      play_song :tune
      game_loop {}
    end
  end

  # Drums on the noise voice, one hit swelling. A drum low enough to rumble steps a few times a frame,
  # and a frame of it says more about where its steps fell than how loud it is, so these are high.
  def test_drums_that_ring_and_swell_sound_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 130, hiss: true) do
      enable_sound
      song :tune do
        tempo 120
        voice(:drums, plays: :noise) { decay :slow; note :E5, :quarter; note :C6, :quarter, swell: 2; rest :half }
      end
      play_song :tune
      game_loop {}
    end
  end

  # Notes that slide up and down, and wobble.
  def test_notes_that_slide_and_wobble_sound_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 130) do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) do
          vibrato depth: 9, speed: 3, after: 6
          note :C5, :quarter, slide_up: :fast, vibrato: :none
          note :A4, :half
          note :G4, :quarter, slide_down: :slow, vibrato: :none
        end
      end
      play_song :tune
      game_loop {}
    end
  end

  # A note stepping through four shapes a frame.
  def test_a_note_changing_shape_sounds_as_on_the_playstation
    assert_sounds_like_the_playstation(frames: 80) do
      enable_sound
      song :tune do
        tempo 120
        voice(:melody) { duty %i[eighth quarter half three_quarter]; note :E4, :whole }
      end
      play_song :tune
      game_loop {}
    end
  end

  # A part moving from one speaker to the other, heard from each.
  def test_a_part_on_one_speaker_sounds_as_on_the_playstation
    %i[left right].each do |side|
      assert_sounds_like_the_playstation(frames: 100, side: side) do
        enable_sound
        song :tune do
          tempo 120
          voice(:melody) { pan :left; note :A4, :half; note :C5, :half, pan: :right }
        end
        play_song :tune
        game_loop {}
      end
    end
  end


  private

  def assert_sounds_like_the_playstation(frames:, side: :left, hiss: false, &game)
    builder = VBlank::Builder.new
    builder.instance_eval(&game)
    builder.finalize_program
    program = builder.program.copy.tap { |copy| copy.console = :ps1 }

    beetle = frames_of(beetle_samples(program, frames + MOST_FRAMES_APART + 2, side), BEETLE_RATE, BEETLE_LOUDNESS)
    native = frames_of(native_samples(program, frames, side), NATIVE_RATE, 1)
    first_beetle = beetle.index { |frame| frame.loudness >= FULL_LOUDNESS * HEARD }
    first_native = native.index { |frame| frame.loudness >= FULL_LOUDNESS * HEARD }
    refute_nil first_native, "the desktop build made no sound"
    refute_nil first_beetle, "the PlayStation program made no sound"

    later = first_beetle - first_native
    differing, compared = (later - 1..later + 1).map { |apart| differences(beetle, native, apart, hiss) }.min_by { |list, _| list.length }
    assert_operator compared, :>=, frames / 4, "too few frames held a note or a hiss long enough to compare"
    assert_empty differing.first(8), "the desktop build does not sound like the PlayStation (#{differing.length} frames differ)"
  end

  def beetle_samples(program, frames, side)
    run = PS1::HeadlessRun.new(keep_sound: true)
    run.run(program, frames: frames)
    run.sound_made.each_slice(2).map { |left, right| side == :left ? left : right }
  end

  def native_samples(program, frames, side)
    run = Native::HeadlessRun.new
    run.recording_sound
    played = run.run(program, frames: frames)
    side == :left ? played.sound : played.sound_right
  end

  # Each frame of +samples+, made +rate+ a second and taken +louder+ times as loud, read without its
  # first and last EDGE_SAMPLES: a change the frame boundary brings lands a few samples after it on the
  # desktop build and a few before it in Beetle, and those few samples would read as a frame halfway
  # between two.
  def frames_of(samples, rate, louder)
    count = (samples.length / (rate * FRAME_SECONDS)).floor
    (0...count).map do |index|
      first = (index * rate * FRAME_SECONDS).floor + EDGE_SAMPLES
      part = samples[first...(((index + 1) * rate * FRAME_SECONDS).floor - EDGE_SAMPLES)]
      rises = (0...(part.length - 1)).filter_map do |at|
        (first + at + (-part[at] / (part[at + 1] - part[at]).to_f)) / rate if part[at].negative? && part[at + 1] >= 0
      end
      Frame.new(loudness: Math.sqrt(part.sum { |sample| sample * sample } / part.length.to_f) * louder, rises: rises)
    end
  end

  # Every frame that differs, in words, with Beetle's frames taken to be +apart+ after the desktop
  # build's; and how many frames' pitch or rises were compared.
  def differences(beetle, native, apart, hiss)
    compared = 0
    differing = native.each_index.filter_map do |index|
      at = index + apart
      next if at - 1 < 0 || at + 1 >= beetle.length

      near = [at - 1, at, at + 1].map { |frame| beetle[frame].loudness }
      unless near.any? { |loud| (loud - native[index].loudness).abs <= FULL_LOUDNESS * LOUDNESS_SLACK }
        next format("frame %d: as loud as %.0f, and the PlayStation %.0f", index, native[index].loudness, beetle[at].loudness)
      end
      next if index.zero? || index + 1 >= native.length

      wrong = pitch_difference(beetle, native, at, index) unless hiss
      wrong ||= rises_difference(beetle, native, at, index)
      next if wrong.nil?

      compared += 1
      wrong.first
    end
    [differing, compared]
  end

  # Where Beetle holds one note at one loudness through a frame and the frames either side, the desktop
  # build's pitch through its three; nil where Beetle does not.
  def pitch_difference(beetle, native, at, index)
    return nil unless [at - 1, at + 1].all? { |frame| (beetle[frame].loudness - beetle[at].loudness).abs <= FULL_LOUDNESS * LOUDNESS_SLACK }

    wanted = steady_pitch(beetle[(at - 1)..(at + 1)]) or return nil
    played = steady_pitch(native[(index - 1)..(index + 1)])
    return [format("frame %d: no one note is held, and the PlayStation holds %.1f Hz", index, wanted)] if played.nil?
    return [format("frame %d: at %.2f Hz, and the PlayStation at %.2f", index, played, wanted)] if (played - wanted).abs > wanted * PITCH_SLACK

    [nil]
  end

  # The pitch three frames hold, from how far apart their rises are, or nil when they are too quiet or
  # their waves are not all one length.
  def steady_pitch(frames)
    return nil unless frames.all? { |frame| frame.loudness >= FULL_LOUDNESS * HEARD }

    rises = frames.flat_map(&:rises)
    waves = rises.each_cons(2).map { |from, to| to - from }
    return nil if waves.length < 6

    usual = waves.sort[waves.length / 2]
    return nil unless waves.all? { |wave| (wave - usual).abs <= usual * STEADY || (wave - usual).abs > usual * 0.5 }

    whole = waves.select { |wave| (wave - usual).abs <= usual * STEADY }
    whole.length / whole.sum
  end

  # Where Beetle is heard through a frame and the frames either side, how often the desktop build's sound
  # rises through nought in those three, against Beetle's: how bright a hiss is, and for voices heard
  # together, which have no one pitch to read, their pitches together.
  def rises_difference(beetle, native, at, index)
    return nil unless (at - 2..at + 2).all? { |frame| beetle.fetch(frame, nil)&.loudness.to_f >= FULL_LOUDNESS * HEARD }

    played = [index - 1, index, index + 1].sum { |frame| native[frame].rises.length }
    wanted = [at - 1, at, at + 1].map do |middle|
      (middle - 1..middle + 1).sum { |frame| beetle.fetch(frame, nil)&.rises&.length || 0 }
    end
    return [nil] if wanted.any? { |count| (played - count).abs <= (count * RISES_SLACK) + 1 }

    [format("frame %d: rising %d times in three frames, and the PlayStation %d", index, played, wanted[1])]
  end
end
