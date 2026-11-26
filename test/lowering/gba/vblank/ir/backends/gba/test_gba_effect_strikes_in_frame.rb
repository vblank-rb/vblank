# frozen_string_literal: true

require "test_helper"
require "effect_strikes_heard"

# A sound effect on a timer, struck inside the frame on the Advance (GBA::EffectStrikes). Its notes
# are as far apart in time as their ticks, not rounded to the frames they fall in: a tick of 50 a
# second is a frame and a fifth, so notes three ticks apart are 60 milliseconds apart, where frames
# would put them three or four frames apart, 50 or 67. Each note's register writes wait on a list
# for their line of the screen, and a hardware timer's interrupt writes them (GBATEK, "GBA Timers"),
# or the line-match interrupt where the game holds every timer (GBATEK, "LCD I/O Interrupts and
# Status").
#
# Measured in the emulator's sound: where each note is first heard, rising out of the silence the
# one before it left, in frames from power-on: the frame whose sound holds it, and how far through
# that frame's sample pairs it is. The emulator gives a frame's sound out over a few pairs more or
# fewer from frame to frame, so a place counted in pairs from power-on drifts against the console's
# own clock, and a place in its frame does not.
class TestGBAEffectStrikesInFrame < Minitest::Test
  include EffectStrikesHeard

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  HEARD_ABOVE = 400
  SILENCE = 120 # pairs no louder than that in a row: longer than any wave of the note passing nought
  PLAYED_ON = 10
  FRAMES = 120
  # Within a millisecond of the tick's own time: a line is some 73 microseconds, and a note is
  # first heard above HEARD_ABOVE up to half a wave after it starts, some 0.7 milliseconds at E5, by
  # where in its wave the voice begins. Frames would put a note out by a fifth of a frame or more,
  # 3 milliseconds.
  NEAR_SECONDS = Rational(1, 1000)
  # The pass of a game that does this much work in each takes two frames or more (the test checks).
  SLOW_WORK = 100_000

  # +notes+ notes +apart+ ticks apart, each +lasting+ ticks then a rest, at +rate+ ticks a second.
  # With +work+ each pass of the game counts that high first. The effect plays on pass +played_on+.
  # +timers+ named timers the game counts with, which take the hardware's every timer at 2.
  # +recordings+ silent recordings looping from the second pass, which the mix works through.
  private def game(rate:, apart:, lasting:, notes: 5, work: 0, timers: 0, recordings: 0)
    struck = (0...notes).map { |n| Note.new(at: n * apart, key: :E5, length: lasting) }
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: notes * apart, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: struck)])
    VBlank.build("STRIKES", console: :gba, out: nil, err: nil) do
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      busy = var :busy, 0
      seen = var :seen, 0
      clocks = Array.new(timers) { |n| timer :"clock#{n}", per_second: 1000 }
      loops = Array.new(recordings) { |n| sample :"quiet#{n}", pcm: Array.new(3001 + n, 0), rate: 16_000 }
      game_loop do
        pass += 1
        loops.each { |clip| clip.play(loop: true) } if pass == 2
        sfx.play :chime if pass == PLAYED_ON
        repeat(work) { busy += 1 } if work.positive?
        clocks.each { |clock| seen.store! clock.ticks }
      end
    end
  end

  Heard = Data.define(:onsets, :passes)

  # The frame, with the share of it gone by, each note is first heard at, and how many passes the
  # game played.
  private def heard(cartridge, frames: FRAMES)
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    quiet_for = SILENCE
    onsets = []
    frames.times do |frame|
      reader.step(1)
      pairs = reader.last_frame_samples.each_slice(2).map { |pair| pair.map(&:abs).max }
      pairs.each_with_index do |loudness, at|
        onsets << (frame + Rational(at, pairs.size)) if quiet_for >= SILENCE && loudness > HEARD_ABOVE
        quiet_for = loudness > HEARD_ABOVE ? 0 : quiet_for + 1
      end
    end
    Heard.new(onsets: onsets, passes: reader.var(:pass))
  ensure
    reader&.close
  end

  private def assert_struck_apart(rate:, apart:, lasting:, notes: 5, **)
    sound = heard(game(rate: rate, apart: apart, lasting: lasting, notes: notes, **))
    yield sound if block_given?
    frame_seconds = VBlank::Console::ADVANCE.frame_seconds
    expected = Rational(apart, rate) / frame_seconds
    shown = sound.onsets.map { |at| at.to_f.round(3) }

    assert_equal notes, sound.onsets.size, "every note heard on its own: #{shown.inspect}"
    # The first note is struck as the effect starts, at the frame's start (Reference::Player#advance);
    # the notes after it are struck on their ticks.
    sound.onsets.drop(1).each_cons(2) do |was, now|
      assert_in_delta expected, now - was, NEAR_SECONDS / frame_seconds,
                      "notes #{apart} ticks apart at #{rate} a second, #{expected.to_f.round(3)} frames: #{shown.inspect}"
    end
  end

  def test_notes_a_frame_and_a_fifth_of_ticks_apart_are_struck_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1)
  end

  # Four ticks a frame: each note falls on whichever of its frame's ticks it does, two and a half
  # frames apart, so each is heard alone: the emulator's speaker takes some 20 milliseconds to
  # settle once a rest switches the voice off.
  def test_notes_on_later_ticks_of_a_frame_are_struck_at_their_own_ticks
    assert_struck_apart(rate: 240, apart: 10, lasting: 3)
  end

  # The screen's interrupt plays the sound a frame at a time whatever the game is doing, so a game
  # whose pass takes several frames strikes its notes as far apart as one that keeps up.
  def test_a_game_slower_than_the_frames_strikes_its_notes_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, notes: 8, work: SLOW_WORK) do |sound|
      assert_operator sound.passes, :<=, FRAMES / 2, "every pass takes two frames or more"
    end
  end

  # Two timers whose ticks the game reads take all four of the hardware's, so the strikes wait for
  # their lines on the line-match interrupt instead.
  def test_a_game_holding_every_timer_strikes_its_notes_on_their_lines
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, timers: 2)
  end

  # The mix of recordings runs in an interrupt of its own for much of the frame, and holds the
  # strikes' interrupt off while it does: it looks for one between voices. Eight recordings
  # mixing held a strike off by some 3 milliseconds.
  def test_a_game_mixing_recordings_strikes_its_notes_while_the_mix_runs
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, notes: 6, recordings: 8)
  end

  # A note struck part way through a frame on a voice still sounding the note before, the new one
  # wobbling or stepping its shape from its first frame: the frame's end moves the voice's pitch or
  # shape for it before the strike comes. Folded into the strike's own listed writes, it does not
  # reach the voice before the strike: until the frame of the strike the writes to the sound chip
  # are those of the same notes without the wobble or the shapes, and on that frame they are the same
  # registers, in the same order, the strike's values carrying the change.
  #
  # Read as writes, frame by frame (Verifier#watch_sound), not as sound: two builds of different
  # length strike a note a few cycles apart, which moves its wave by part of a sample.
  FIRST = Note.new(at: 0, key: :E5, length: 3, volume: 15)

  private def writes_of_notes(*notes)
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 12, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: notes)])
    cartridge = VBlank.build("STRIKES", console: :gba, out: nil, err: nil) do
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        sfx.play :chime if pass == PLAYED_ON
      end
    end
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    reader.watch_sound
    Array.new(PLAYED_ON + 30) do
      reader.step(1)
      reader.sound_writes.map { |write| [write.address, write.value] }
    end
  ensure
    reader&.close
  end

  private def assert_unchanged_until_struck(second)
    plain = writes_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 9, volume: 10))
    changed = writes_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 9, volume: 10, **second))
    struck = plain.zip(writes_of_notes(FIRST)).index { |with, without| with != without }

    refute_nil struck, "the second note is struck"
    assert_equal plain.first(struck), changed.first(struck), "the writes before the strike's frame"
    assert_equal plain[struck].map(&:first), changed[struck].map(&:first), "the registers the strike's frame writes"
    refute_equal plain[struck], changed[struck], "the strike carries the change"
  end

  def test_a_wobble_stepped_before_its_note_is_struck_waits_for_the_strike
    assert_unchanged_until_struck(vibrato: { depth: 15, speed: 1, after: 0 })
  end

  def test_a_shape_stepped_before_its_note_is_struck_waits_for_the_strike
    assert_unchanged_until_struck(duty: %i[eighth half])
  end

  # An effect from the left speaker alone on both square voices, and the game's own beep on the second
  # every pass, from both: the beep's pass comes after the frame's effects are played and before their
  # strike, and its write of the speakers' switches folds into the listed one, so the beep keeps its
  # voice on both speakers as it does where the effect plays at the frame's start. Read as SOUNDCNT_L's
  # switch for the second voice's right speaker at each frame's end (GBATEK, "GBA Sound Control
  # Registers"), in the 72 bytes of sound registers from 4000060h.
  SOUNDCNT_L_AT = 0x20
  SECOND_VOICE_RIGHT = 0x0200

  # SOUNDCNT_L at each frame's end, from the frame after the effect starts. With +song+ a tune's
  # second square part plays from the right on every frame in place of the beep, its note set at the
  # frame's end by the player.
  private def speaker_switches(on_timer:, song: false)
    notes = ->(key) { (0...8).map { |n| Note.new(at: n * 3, key: key, length: 1, volume: 15) } }
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 24, plays_once: true, on_timer: on_timer,
                       parts: [Part.new(pan: :left, notes: notes.call(:E5)), Part.new(pan: :left, notes: notes.call(:A5))])
    tune = Score.new(tempo: 900, ticks_per_beat: 1, priority: 255,
                     parts: [Part.new(notes: [Note.new(at: 0, key: :C4, length: 1, volume: 2)]),
                             Part.new(pan: :right, notes: [Note.new(at: 0, key: :G4, length: 1, volume: 2)])])
    cartridge = VBlank.build("STRIKES", console: :gba, out: nil, err: nil) do
      enable_sound
      define_sound :ping, frequency: 1500, duty: :half, decay: :none, volume: 15
      music = (songs :music, [tune] if song)
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        music&.play 0
        sfx.play :chime if pass == PLAYED_ON
        beep :ping if !song && pass >= PLAYED_ON
      end
    end
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    Array.new(PLAYED_ON + 35) do
      reader.step(1)
      reader.sound_registers.byteslice(SOUNDCNT_L_AT, 2).unpack1("v")
    end.drop(PLAYED_ON + 2)
  ensure
    reader&.close
  end

  def test_the_games_beep_after_a_listed_speaker_write_keeps_its_speakers
    struck = speaker_switches(on_timer: true).count { |switches| switches.nobits?(SECOND_VOICE_RIGHT) }

    assert_equal 0, speaker_switches(on_timer: false).count { |switches| switches.nobits?(SECOND_VOICE_RIGHT) }, "the effect at the frame's start"
    assert_equal 0, struck, "the effect struck inside the frame"
  end

  # A song that outranks the effect sets its voices' switches on every frame through the same fold, and
  # they land as where the effect plays at the frame's start.
  def test_a_songs_speakers_after_a_listed_speaker_write_are_kept
    assert_equal speaker_switches(on_timer: false, song: true), speaker_switches(on_timer: true, song: true)
  end

  # The game's own sound over the effect (EffectStrikesHeard), within 1/20 of a frame of where it
  # is heard with the effect at the frame's start.
  GAME_SOUND_NEAR = Rational(1, 20)

  def test_the_games_beep_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:gba, :beep, near: GAME_SOUND_NEAR)
  end

  def test_the_games_wave_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:gba, :wave, near: GAME_SOUND_NEAR)
  end

  def test_the_tune_taking_back_a_voice_the_effect_lets_go_is_heard_on
    assert_tune_heard_after_effect_lets_go(:gba)
  end
end
