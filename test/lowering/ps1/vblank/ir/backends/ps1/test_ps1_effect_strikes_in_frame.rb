# frozen_string_literal: true

require "test_helper"
require "effect_strikes_heard"

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
  include EffectStrikesHeard

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
  # With +work+ each pass of the game counts that high first. The effect plays on pass +played_on+.
  private def game(rate:, apart:, lasting:, notes: 5, work: 0, played_on: PLAYED_ON)
    VBlank.build("STRIKES", console: :ps1, out: nil, err: nil,
                 &game_code(rate: rate, apart: apart, lasting: lasting, notes: notes, work: work, played_on: played_on))
  end

  # ...as a program, for a checked run.
  private def game_program(**)
    builder = Builder.new
    builder.instance_eval(&game_code(**))
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :ps1 }
  end

  private def game_code(rate:, apart:, lasting:, notes: 5, work: 0, played_on: PLAYED_ON, work_on: nil)
    struck = (0...notes).map { |n| Note.new(at: n * apart, key: :E5, length: lasting) }
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: notes * apart, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: struck)])
    proc do
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      busy = var :busy, 0
      game_loop do
        pass += 1
        sfx.play :chime if pass == played_on
        if work_on
          repeat(work) { busy += 1 } if pass == work_on
        elsif work.positive?
          repeat(work) { busy += 1 }
        end
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
    # The first note is struck as the effect starts, at the frame's start (Reference::Player#advance);
    # the notes after it are struck on their ticks.
    sound.onsets.drop(1).each_cons(2) do |was, now|
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

  # A note struck part way through a frame on a voice still sounding the note before, the new note
  # fading from its first frame: E5 at full loudness, then A5 softer and fading. The frame boundary
  # steps the fade before the strike comes. The note before keeps its own loudness until the strike,
  # and the new note is heard at its stepped loudness from the strike on, not the loudness it was
  # listed with. Read as the loudest sample in each LOUDNESS_PAIRS pairs, beside the same notes with
  # no fade, which sound alike until the strike.
  LOUDNESS_PAIRS = 64
  private def loudness_of_two_notes(fading)
    notes = [Note.new(at: 0, key: :E5, length: 3, volume: 15),
             Note.new(at: 3, key: :A5, length: 9, volume: 10, decay: (1 if fading))]
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 12, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: notes)])
    cartridge = VBlank.build("STRIKES", console: :ps1, out: nil, err: nil) do
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
    left.each_slice(LOUDNESS_PAIRS).map { |run| run.map(&:abs).max }
  ensure
    reader&.close
  end

  def test_a_fade_stepped_before_its_note_is_struck_waits_for_the_strike
    plain = loudness_of_two_notes(false)
    fading = loudness_of_two_notes(true)
    heard = plain.index { |loud| loud > HEARD_ABOVE }
    struck = (heard + 1...plain.size).find { |at| (plain[at] - plain[at - 1]).abs > HEARD_ABOVE }
    apart = plain.zip(fading).index { |was, now| (was - now).abs > HEARD_ABOVE }

    assert_operator apart, :>=, struck, "the note before changed loudness before the strike: #{fading[(struck - 4)..(struck + 4)].inspect}"
    assert_operator fading[struck + 1], :<, plain[struck + 1], "the struck note at its stepped loudness"
  end

  # The checked run holds the sound chip to the interpreter's log at every pass, those whose notes are
  # still listed to be struck among them: it reads the chip as those writes leave it. One pass of the
  # game takes several frames as the effect plays, and the passes after it end while the notes of the
  # frames it took are still listed.
  def test_the_checked_run_reads_the_chip_at_every_pass_while_notes_wait_to_be_struck
    frames = PLAYED_ON + 30
    slow_once = { rate: 50, apart: 3, lasting: 1, work: SLOW_WORK, work_on: PLAYED_ON + 1 }
    run = VBlank::IR::Backends::PS1::CheckedRun.new.run(game_program(**slow_once), frames: frames)
    quiet = VBlank::IR::Backends::PS1::CheckedRun.new.run(game_program(**slow_once, played_on: frames * 2), frames: frames)

    assert_equal quiet.spu_reads.size, run.spu_reads.size
  end

  # The game's own sound over the effect (EffectStrikesHeard), within a tenth of a frame of where it is
  # heard with the effect at the frame's start: the game's sound is keyed on as the next frame begins
  # either way. Folded into the listed writes, its pitch and volume wait for the strike's line, which
  # keys the effect's note on over it.
  GAME_SOUND_NEAR = Rational(1, 10)

  def test_the_games_beep_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:ps1, :beep, near: GAME_SOUND_NEAR)
  end

  def test_the_games_wave_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:ps1, :wave, near: GAME_SOUND_NEAR)
  end

  def test_the_tune_taking_back_a_voice_the_effect_lets_go_is_heard_on
    assert_tune_heard_after_effect_lets_go(:ps1)
  end
end
