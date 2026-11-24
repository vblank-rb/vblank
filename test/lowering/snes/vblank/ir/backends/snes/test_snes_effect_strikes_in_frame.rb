# frozen_string_literal: true

require "test_helper"

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
  # +song+ a tune plays beside them on a voice of its own.
  private def game(rate:, apart:, lasting:, notes: 5, keys: [:E5], work: 0, song: false)
    struck = (0...notes).map { |n| Note.new(at: n * apart, key: keys[n % keys.size], length: lasting) }
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: notes * apart, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: struck)])
    VBlank.build("STRIKES", console: :snes, out: nil, err: nil) do
      enable_sound
      if song
        song(:tune) { voice(:lead) { 64.times { note :C3, :quarter } } }
        play_song :tune
      end
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      busy = var :busy, 0
      game_loop do
        pass += 1
        sfx.play :chime if pass == PLAYED_ON
        repeat(work) { busy += 1 } if work.positive?
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
end
