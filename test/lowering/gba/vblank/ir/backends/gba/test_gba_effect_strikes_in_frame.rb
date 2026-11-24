# frozen_string_literal: true

require "test_helper"

# A sound effect on a timer, struck inside the frame on the Advance (GBA::EffectStrikes). Its notes
# are as far apart in time as their ticks, not rounded to the frames they fall in: a tick of 50 a
# second is a frame and a fifth, so notes three ticks apart are 60 milliseconds apart, where frames
# would put them three or four frames apart, 50 or 67. Each note's register writes wait on a list
# for their line of the screen, and a hardware timer's interrupt writes them (GBATEK, "GBA Timers"),
# or the line-match interrupt where the game holds every timer (GBATEK, "LCD I/O Interrupts and
# Status").
#
# Measured in the emulator's sound: where each note is first heard, rising out of the silence the
# one before it left, counted in sample pairs from power-on, and the pairs a second the emulator
# gives out, from how many its frames held.
class TestGBAEffectStrikesInFrame < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  HEARD_ABOVE = 400
  SILENCE = 120 # pairs no louder than that in a row: longer than any wave of the note passing nought
  PLAYED_ON = 10
  FRAMES = 120
  # Within this many pairs of the tick's own time, about a millisecond: a line is some 73
  # microseconds, and a note is first heard above HEARD_ABOVE up to half a wave after it starts,
  # some 33 pairs at E5, by where in its wave the voice begins. Frames would put a note out by a
  # fifth of a frame or more, some 150.
  NEAR = 48
  # The pass of a game that does this much work in each takes two frames or more (the test checks).
  SLOW_WORK = 100_000

  # +notes+ notes +apart+ ticks apart, each +lasting+ ticks then a rest, at +rate+ ticks a second.
  # With +work+ each pass of the game counts that high first. The effect plays on pass +played_on+.
  # +timers+ named timers the game counts with, which take the hardware's every timer at 2.
  private def game(rate:, apart:, lasting:, notes: 5, work: 0, timers: 0)
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
      game_loop do
        pass += 1
        sfx.play :chime if pass == PLAYED_ON
        repeat(work) { busy += 1 } if work.positive?
        clocks.each { |clock| seen.store! clock.ticks }
      end
    end
  end

  Heard = Data.define(:onsets, :pairs_a_second, :passes, :pairs)

  # The sample pair, counted from power-on, each note is first heard at, the pairs a second, how
  # many passes the game played, and each pair's loudness.
  private def heard(cartridge, frames: FRAMES)
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    pairs = []
    frames.times do
      reader.step(1)
      pairs.concat(reader.last_frame_samples.each_slice(2).map { |pair| pair.map(&:abs).max })
    end
    quiet_for = SILENCE
    onsets = pairs.each_with_index.filter_map do |loudness, at|
      rises = quiet_for >= SILENCE && loudness > HEARD_ABOVE
      quiet_for = loudness > HEARD_ABOVE ? 0 : quiet_for + 1
      at if rises
    end
    Heard.new(onsets: onsets, pairs_a_second: Rational(pairs.size, frames) / VBlank::Console::ADVANCE.frame_seconds,
              passes: reader.var(:pass), pairs: pairs)
  ensure
    reader&.close
  end

  private def assert_struck_apart(rate:, apart:, lasting:, notes: 5, **)
    sound = heard(game(rate: rate, apart: apart, lasting: lasting, notes: notes, **))
    yield sound if block_given?
    expected = apart * sound.pairs_a_second / rate

    assert_equal notes, sound.onsets.size, "every note heard on its own: #{sound.onsets.inspect}"
    sound.onsets.each_cons(2) do |was, now|
      assert_in_delta expected, now - was, NEAR,
                      "notes #{apart} ticks apart at #{rate} a second, #{expected.round} pairs: #{sound.onsets.inspect}"
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

  # A note struck part way through a frame on a voice still sounding the note before, the new one
  # wobbling or stepping its shape from its first frame: the frame's end moves the voice's pitch or
  # shape for it before the strike comes. The note before keeps its own until the strike: the
  # sound is the same as the same notes without the wobble or the shapes until then. Where the strike
  # comes is where the sound first parts from the note before alone, ended by a rest at that tick.
  FIRST = Note.new(at: 0, key: :E5, length: 3, volume: 15)

  private def samples_of_notes(*notes)
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
    left = []
    (PLAYED_ON + 30).times do
      reader.step(1)
      left.concat(reader.last_frame_samples.each_slice(2).map(&:first))
    end
    left
  ensure
    reader&.close
  end

  private def assert_unchanged_until_struck(second)
    alone = samples_of_notes(FIRST)
    plain = samples_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 9, volume: 10))
    changed = samples_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 9, volume: 10, **second))
    struck = alone.zip(plain).index { |was, now| was != now }
    apart = plain.zip(changed).index { |was, now| was != now }

    assert_operator apart, :>=, struck, "the note before changed at pair #{apart}, before the strike at #{struck}"
  end

  def test_a_wobble_stepped_before_its_note_is_struck_waits_for_the_strike
    assert_unchanged_until_struck(vibrato: { depth: 15, speed: 1, after: 0 })
  end

  def test_a_shape_stepped_before_its_note_is_struck_waits_for_the_strike
    assert_unchanged_until_struck(duty: %i[eighth half])
  end
end
