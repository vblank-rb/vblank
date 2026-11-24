# frozen_string_literal: true

require "test_helper"
require "effect_strikes_heard"

# A sound effect on a timer, struck inside the frame on the Super Nintendo (Runtime::Strikes). Its
# notes are as far apart in time as their ticks, not rounded to the frames they fall in: a tick of
# 50 a second is a frame and a fifth, so notes three ticks apart are 60 milliseconds apart, where
# frames would put them three or four frames apart, 50 or 67. A console's own sound driver runs its
# effects on the sound unit's timer 0 and keys each note on as its tick comes (fullsnes, "SNES APU
# SPC700 I/O Ports").
#
# Measured in the emulator's sound: where each note is first heard, rising out of the silence the
# one before it left, counted in sample pairs from power-on, and the pairs a second the emulator
# gives out, from how many its frames held.
class TestSNESEffectStrikesInFrame < Minitest::Test
  include EffectStrikesHeard

  DSP = VBlank::IR::Backends::SNES::DSPWrites
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  HEARD_ABOVE = 400
  SILENCE = 160 # pairs no louder than that in a row: longer than any wave of the note passing nought
  PLAYED_ON = 10
  FRAMES = 120
  # Within this many pairs of the tick's own time, about a millisecond: a count of the sound unit's
  # timer is an eighth of one, and the console sends each frame's mark a little after the frame
  # begins, not always alike. Frames would put a note out by a fifth of a frame or more, some 160.
  NEAR = 48
  # The pass of a game that does this much work in each takes two frames or more (the test checks).
  SLOW_WORK = 9000

  # +notes+ notes +apart+ ticks apart, each +lasting+ ticks then a rest, at +rate+ ticks a second,
  # their keys +keys+ in turn. With +work+ each pass of the game counts that high first, and with
  # +song+ a tune of three parts, a note on each every sixteenth, plays beside them. The effect plays
  # on the first pass +played_on+ frames from power-on or later: counted in frames, not passes, since
  # the build with the tune sends a longer sound program and starts its passes later, and its notes
  # are compared with those of the build without at the same moments.
  private def game(**) = VBlank.build("STRIKES", console: :snes, out: nil, err: nil, &game_code(**))

  # ...as a program, for a checked run.
  private def game_program(**)
    builder = Builder.new
    builder.instance_eval(&game_code(**))
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :snes }
  end

  private def game_code(rate:, apart:, lasting:, notes: 5, keys: [:E5], work: 0, song: false, played_on: PLAYED_ON,
                          slow_once_on: nil)
    struck = (0...notes).map { |n| Note.new(at: n * apart, key: keys[n % keys.size], length: lasting) }
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: notes * apart, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: struck)])
    proc do
      enable_sound
      if song
        song(:tune) do
          voice(:low) { 256.times { note :C3, :sixteenth } }
          voice(:middle) { 256.times { note :G3, :sixteenth } }
          voice(:high, plays: :wave) { 256.times { note :C4, :sixteenth } }
        end
        play_song :tune
      end
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      started = var :started, 0
      busy = var :busy, 0
      slowed = var :slowed, 0
      game_loop do
        pass += 1
        if started == 0 && frames_since_power_on >= played_on
          started = 1
          sfx.play :chime
        end
        repeat(work) { busy += 1 } if work.positive?
        if slow_once_on
          if slowed == 0 && frames_since_power_on >= slow_once_on
            slowed = 1
            repeat(SLOW_WORK) { busy += 1 }
          end
        end
      end
    end
  end

  Heard = Data.define(:onsets, :pairs_a_second, :left, :passes)

  # The sample pair, counted from power-on, each note is first heard at, the pairs a second, and the
  # left side's samples, and how many passes the game played.
  private def heard(cartridge)
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    reader.hearing(only: [:"voice#{DSP::CHANNEL_VOICES.fetch(1)}"])
    pairs = []
    left = []
    FRAMES.times do
      reader.step(1)
      samples = reader.last_frame_samples
      pairs.concat(samples.each_slice(2).map { |pair| pair.map(&:abs).max })
      left.concat(samples.each_slice(2).map(&:first))
    end
    quiet_for = SILENCE
    onsets = pairs.each_with_index.filter_map do |loudness, at|
      rises = quiet_for >= SILENCE && loudness > HEARD_ABOVE
      quiet_for = loudness > HEARD_ABOVE ? 0 : quiet_for + 1
      at if rises
    end
    Heard.new(onsets: onsets, pairs_a_second: Rational(pairs.size, FRAMES) / VBlank::Console::SUPER_NINTENDO.frame_seconds,
              left: left, passes: reader.var(:pass))
  ensure
    reader&.close
  end

  private def assert_struck_apart(rate:, apart:, lasting:, notes: 5, **)
    sound = heard(game(rate: rate, apart: apart, lasting: lasting, notes: notes, **))
    yield sound if block_given?
    expected = apart * sound.pairs_a_second / rate

    assert_equal notes, sound.onsets.size, "every note heard on its own: #{sound.onsets.inspect}"
    sound.onsets.each_cons(2) do |was, now|
      assert_in_delta expected, now - was, NEAR, "notes #{apart} ticks apart at #{rate} a second: #{sound.onsets.inspect}"
    end
  end

  def test_notes_a_frame_and_a_fifth_of_ticks_apart_are_struck_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1)
  end

  # Four ticks a frame: each note falls on whichever of its frame's ticks it does.
  def test_notes_on_later_ticks_of_a_frame_are_struck_at_their_own_ticks
    assert_struck_apart(rate: 240, apart: 5, lasting: 2)
  end

  # A game whose pass takes several frames plays the music of all of them as its wait ends, one after
  # the other, and sends them together: each frame's notes are struck a frame after the one before's,
  # their ticks apart, not all at once as they come.
  def test_a_game_slower_than_the_frames_strikes_its_notes_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, notes: 8, keys: %i[A5 E5], work: SLOW_WORK) do |sound|
      assert_operator sound.passes, :<=, FRAMES / 2, "every pass takes two frames or more"
    end
  end

  # One pass that takes several frames sends their notes together, struck a frame apart, so they are
  # late. The passes after it are each a frame again, and their notes come back to their ticks within
  # SETTLED_FRAMES of it, rather than staying late by the frames the slow pass took.
  SLOW_ONCE_ON = 24
  SETTLED_FRAMES = 50
  def test_notes_after_one_slow_pass_come_back_to_their_ticks
    steady = heard(game(rate: 50, apart: 3, lasting: 1, notes: 24, keys: %i[A5 E5]))
    slowed = heard(game(rate: 50, apart: 3, lasting: 1, notes: 24, keys: %i[A5 E5], slow_once_on: SLOW_ONCE_ON))
    settled_from = (SLOW_ONCE_ON + SETTLED_FRAMES) * steady.pairs_a_second * VBlank::Console::SUPER_NINTENDO.frame_seconds
    expected = steady.onsets.select { |at| at >= settled_from }
    got = slowed.onsets.select { |at| at >= settled_from - NEAR }.first(expected.size)

    refute_empty expected
    assert_equal expected.size, got.size, "notes after the slow pass: #{got.inspect}, steady: #{expected.inspect}"
    expected.zip(got).each { |want, have| assert_in_delta want, have, NEAR, "notes after the slow pass: #{got.inspect}, steady: #{expected.inspect}" }
  end

  # The length of the effect's voice's wave a little after each of +onsets+, in pairs: the middle
  # distance between its rises through nought over PITCH_WINDOW pairs. A5's wave is 55 pairs at the
  # emulator's 48,000 a second, E5's 73.
  PITCH_WINDOW = 400
  WAVE_NEAR = 4
  private def wave_lengths_after(sound, onsets)
    onsets.map do |at|
      rises = sound.left[(at + 60)...(at + 60 + PITCH_WINDOW)].each_cons(2).each_with_index
                   .filter_map { |(was, now), i| i if was.negative? && !now.negative? }
      apart = rises.each_cons(2).map { |a, b| b - a }.sort
      apart.empty? ? 0 : apart[apart.size / 2]
    end
  end

  private def assert_same_pitches(alone, beside)
    assert_equal 8, alone.onsets.size
    expected = wave_lengths_after(alone, alone.onsets)
    got = wave_lengths_after(beside, alone.onsets)
    expected.zip(got).each do |want, have|
      assert_in_delta want, have, WAVE_NEAR, "each note's wave beside the tune: #{got.inspect}, alone: #{expected.inspect}"
    end
  end

  # A tune beside the effect keeps the line busy, so a note's pitch and the note itself can come in
  # different turns of the sound unit's wait, with one of the list's notes struck between them. Each
  # note is still heard at its own pitch, as without the tune.
  def test_each_note_keeps_its_own_pitch_beside_a_tune
    assert_same_pitches(heard(game(rate: 50, apart: 3, lasting: 2, notes: 8, keys: %i[A5 E5])),
                        heard(game(rate: 50, apart: 3, lasting: 2, notes: 8, keys: %i[A5 E5], song: true)))
  end

  def test_each_note_on_later_ticks_keeps_its_own_pitch_beside_a_tune
    assert_same_pitches(heard(game(rate: 240, apart: 5, lasting: 2, notes: 8, keys: %i[A5 E5])),
                        heard(game(rate: 240, apart: 5, lasting: 2, notes: 8, keys: %i[A5 E5], song: true)))
  end

  # Eight ticks a frame, each striking a note of its own, then G5 held: more than the line ahead holds
  # in a frame, so some of a tick's commands come through the queue, each after the time it was due,
  # and the sound unit does each as it comes. The pitch of a note and the note itself are then done in
  # different turns of its wait, and the note still sounds at its own pitch. Measured over frames
  # HELD_FRAMES, while G5 is held: its wave is 61 pairs, C6's before it 46.
  HELD_FRAMES = (20...28)
  private def held_wave_length(burst)
    notes = (0...burst).map { |n| Note.new(at: n, key: n.even? ? :C4 : :C6, length: 1) }
    notes << Note.new(at: burst, key: :G5, length: 120)
    effect = Score.new(tempo: 480, ticks_per_beat: 60, length: burst + 120, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: notes)])
    cartridge = VBlank.build("STRIKES", console: :snes, out: nil, err: nil) do
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        sfx.play :chime if pass == PLAYED_ON
      end
    end
    sound = heard(cartridge)
    pairs_a_frame = sound.left.size / FRAMES
    window = sound.left[(HELD_FRAMES.begin * pairs_a_frame)...(HELD_FRAMES.end * pairs_a_frame)]
    rises = window.each_cons(2).each_with_index.filter_map { |(was, now), i| i if was.negative? && !now.negative? }
    apart = rises.each_cons(2).map { |a, b| b - a }.sort
    apart[apart.size / 2]
  end

  def test_a_note_after_more_ticks_than_the_line_holds_sounds_at_its_own_pitch
    assert_in_delta held_wave_length(8), held_wave_length(16), WAVE_NEAR
  end

  # The checked run holds the sound unit's registers to the interpreter's log at every pass, those
  # whose notes are still listed to be struck among them: it reads the registers as those commands
  # leave them. A frame's notes are struck a little after their ticks, so a tick late in a frame is
  # still listed as the frame ends.
  def test_the_checked_run_reads_the_registers_at_every_pass_while_notes_wait_to_be_struck
    frames = PLAYED_ON + 30
    run = VBlank::IR::Backends::SNES::CheckedRun.new.run(game_program(rate: 50, apart: 3, lasting: 1), frames: frames)
    quiet = VBlank::IR::Backends::SNES::CheckedRun.new.run(game_program(rate: 50, apart: 3, lasting: 1, played_on: frames * 2),
                                                            frames: frames)

    assert_equal quiet.dsp_reads.size, run.dsp_reads.size
  end

  # The game's own sound over the effect (EffectStrikesHeard), within an eighth of a frame of where it
  # is heard with the effect at the frame's start, at a tick a frame and a fifth, the rate a Super
  # Nintendo sound driver's effects commonly keep. Left on the list, the effect's strike keys its note
  # on over the game's sound part way through the frame.
  #
  GAME_SOUND_NEAR = Rational(1, 8)
  GAME_SOUND_RATE = 50

  # At four ticks a frame, within half a frame. A frame's pass waits while its notes go through the
  # mailboxes, which carry a few dozen commands a frame: a note told whole is two commands, so four
  # ticks are some seventeen with their timing, sent in under half a frame. Sent as nine writes a
  # note, they filled the mailboxes and the game's own sound waited two frames behind them.
  GAME_SOUND_NEAR_AT_FOUR_A_FRAME = Rational(1, 2)

  def test_the_games_beep_is_heard_soon_over_four_ticks_a_frame
    assert_game_sound_heard_over_effect(:snes, :beep, near: GAME_SOUND_NEAR_AT_FOUR_A_FRAME)
  end

  def test_the_games_beep_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:snes, :beep, near: GAME_SOUND_NEAR, rate: GAME_SOUND_RATE)
  end

  def test_the_games_wave_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:snes, :wave, near: GAME_SOUND_NEAR, rate: GAME_SOUND_RATE)
  end

  def test_the_tune_taking_back_a_voice_the_effect_lets_go_is_heard_on
    assert_tune_heard_after_effect_lets_go(:snes)
  end
end
