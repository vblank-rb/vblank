# frozen_string_literal: true

require "test_helper"

# A sound effect on a timer, struck inside the frame on the PlayStation (Runtime::Strikes). Its notes
# are as far apart in time as their ticks, not rounded to the frames they fall in: a tick of 50 a
# second is a frame and a fifth, so notes three ticks apart are 60 milliseconds apart, where frames
# would put them three or four frames apart, 50 or 67. Each key on waits for its line of the screen on
# the second timer, whose interrupt strikes it (psx-spx, "Timers").
#
# Measured in the emulator's sound: where each note is first heard, rising out of the silence the
# one before it left, counted in sample pairs from power-on, and the pairs a second the emulator
# gives out, from how many its frames held.
class TestPS1EffectStrikesInFrame < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  HEARD_ABOVE = 400
  SILENCE = 160 # pairs no louder than that in a row: longer than any wave of the note passing nought
  PLAYED_ON = 10
  FRAMES = 120
  # Within this many pairs of the tick's own time, about a millisecond: a line is some 64
  # microseconds, and the sound chip starts a voice at its next sample. Frames would put a note out
  # by a fifth of a frame or more, some 160.
  NEAR = 48
  # The pass of a game that does this much work in each takes two frames or more (the test checks).
  SLOW_WORK = 300_000

  # +notes+ notes +apart+ ticks apart, each +lasting+ ticks then a rest, at +rate+ ticks a second.
  # With +work+ each pass of the game counts that high first.
  private def game(rate:, apart:, lasting:, notes: 5, work: 0)
    struck = (0...notes).map { |n| Note.new(at: n * apart, key: :E5, length: lasting) }
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: notes * apart, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: struck)])
    VBlank.build("STRIKES", console: :ps1, out: nil, err: nil) do
      enable_sound
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

  Heard = Data.define(:onsets, :pairs_a_second, :passes)

  # The sample pair, counted from power-on, each note is first heard at, the pairs a second, and how
  # many passes the game played.
  private def heard(cartridge)
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    pairs = []
    FRAMES.times do
      reader.step(1)
      pairs.concat(reader.last_frame_samples.each_slice(2).map { |pair| pair.map(&:abs).max })
    end
    quiet_for = SILENCE
    onsets = pairs.each_with_index.filter_map do |loudness, at|
      rises = quiet_for >= SILENCE && loudness > HEARD_ABOVE
      quiet_for = loudness > HEARD_ABOVE ? 0 : quiet_for + 1
      at if rises
    end
    Heard.new(onsets: onsets, pairs_a_second: Rational(pairs.size, FRAMES) / VBlank::Console::PLAYSTATION.frame_seconds,
              passes: reader.var(:pass))
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
  # the other: each frame's notes are struck a frame after the one before's, their ticks apart from
  # when they are listed, not all at once because the lines of the frames they fell in have gone by.
  def test_a_game_slower_than_the_frames_strikes_its_notes_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, notes: 8, work: SLOW_WORK) do |sound|
      assert_operator sound.passes, :<=, FRAMES / 2, "every pass takes two frames or more"
    end
  end
end
