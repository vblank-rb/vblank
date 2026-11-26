# frozen_string_literal: true

require "test_helper"
require "effect_strikes_heard"

# A sound effect on a timer, struck inside the frame on the Genesis (Runtime::Strikes). Its notes are
# as far apart in time as their ticks, not rounded to the frames they fall in: a tick of 50 a second
# is a frame and a fifth, so notes three ticks apart are 60 milliseconds apart, where frames would put
# them three or four frames apart, 50 or 67. Each note's chip writes wait on a list for their line of
# the screen, and the video chip's line interrupt writes them (plutiedev, "Horizontal interrupts").
#
# Measured in the emulator's sound: where each note is first heard, rising out of the silence the
# one before it left, in frames from power-on: the frame whose sound holds it, and how far through
# that frame's sample pairs it is.
class TestGenesisEffectStrikesInFrame < Minitest::Test
  include EffectStrikesHeard

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  HEARD_ABOVE = 400
  SILENCE = 120 # pairs no louder than that in a row: longer than any wave of the note passing nought
  PLAYED_ON = 10
  FRAMES = 120
  NOTES = 14
  # Each note within three and a half milliseconds of every other, against their ticks: a millisecond
  # and a half either way. The line interrupt comes every Runtime::Strikes::STRIDE lines, half a
  # millisecond, but the video chip raises none in the blank, a seventh of the frame, so a tick that
  # falls there is struck as the blank begins or at the first line interrupt after it, whichever is
  # nearer: up to some 23 lines, a millisecond and a half, early or late. Fourteen notes in a row
  # measured here lie within three milliseconds of one another. Frames would put them as far apart
  # as most of a frame, some 13 milliseconds for these.
  NEAR_SPREAD_SECONDS = Rational(7, 2000)
  # The pass of a game that does this much work in each takes two frames or more (the test checks).
  SLOW_WORK = 3000

  # +notes+ notes +apart+ ticks apart, each +lasting+ ticks then a rest, at +rate+ ticks a second, on
  # a square voice, or the wave voice (+plays+). With +work+ each pass of the game counts that high
  # first. The effect plays on pass +played_on+. With +recording+ a silent recording loops from the
  # second pass, so the sound processor holds the FM chip.
  # With +lead_in+ a first note comes two notes' time before the rest, to be left out of what is measured.
  private def game_code(rate:, apart:, lasting:, notes: NOTES, work: 0, recording: false, plays: nil, played_on: PLAYED_ON, work_on: nil,
                        lead_in: false)
    first = lead_in ? apart * 2 : 0
    struck = (0...notes).map { |n| Note.new(at: first + (n * apart), key: :E5, length: lasting) }
    struck.unshift(Note.new(at: 0, key: :E5, length: lasting)) if lead_in
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: first + (notes * apart), plays_once: true, on_timer: true,
                       parts: [Part.new(plays: plays, notes: struck)])
    proc do
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      busy = var :busy, 0
      quiet = (sample :quiet, pcm: Array.new(4000, 0) if recording)
      game_loop do
        pass += 1
        quiet.play(loop: true) if recording && pass == 2
        sfx.play :chime if pass == played_on
        if work_on
          repeat(work) { busy += 1 } if pass == work_on
        elsif work.positive?
          repeat(work) { busy += 1 }
        end
      end
    end
  end

  private def game(**) = VBlank.build("STRIKES", console: :genesis, out: nil, err: nil, &game_code(**))

  # ...as a program, for a checked run.
  private def game_program(**)
    builder = Builder.new
    builder.instance_eval(&game_code(**))
    builder.finalize_program
    builder.program.copy.tap { |program| program.console = :genesis }
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
      next if frame < PLAYED_ON - 1

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

  private def assert_struck_apart(rate:, apart:, lasting:, notes: NOTES, lead_in: false, **)
    sound = heard(game(rate: rate, apart: apart, lasting: lasting, notes: notes, lead_in: lead_in, **))
    yield sound if block_given?
    # The first note is struck as the effect starts, at the frame's start (Reference::Player#advance);
    # the notes after it are struck on their ticks.
    onsets = sound.onsets.drop(1)
    frame_seconds = VBlank::Console::GENESIS.frame_seconds
    off = onsets.each_with_index.map { |at, n| ((at - onsets.first) * frame_seconds) - Rational(n * apart, rate) }
    shown = off.map { |seconds| (seconds * 1000).to_f.round(2) }

    assert_equal lead_in ? notes : notes - 1, onsets.size, "every note heard on its own: #{onsets.map { |at| at.to_f.round(3) }.inspect}"
    assert_operator off.max - off.min, :<=, NEAR_SPREAD_SECONDS,
                    "notes #{apart} ticks apart at #{rate} a second, milliseconds from their ticks against the first: #{shown.inspect}"
  end

  def test_notes_a_frame_and_a_fifth_of_ticks_apart_are_struck_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1)
  end

  # Four ticks a frame: each note falls on whichever of its frame's ticks it does, two and a half
  # frames apart, so each is heard alone.
  def test_notes_on_later_ticks_of_a_frame_are_struck_at_their_own_ticks
    assert_struck_apart(rate: 240, apart: 10, lasting: 3)
  end

  # On the FM chip's voice, which a note keys on and off through its key register.
  def test_notes_on_the_wave_voice_are_struck_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, plays: :sine)
  end

  # A game whose pass takes several frames plays their music one after the other as its wait comes:
  # each frame's notes are struck a frame after the one before's, their ticks apart from when they
  # are listed, not all at once because the lines of the frames they fell in have gone by.
  def test_a_game_slower_than_the_frames_strikes_its_notes_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, notes: 8, work: SLOW_WORK) do |sound|
      assert_operator sound.passes, :<=, FRAMES / 2, "every pass takes two frames or more"
    end
  end

  # A game that plays a recording hands the FM chip to the sound processor, which makes each write
  # the 68000 queues for it between two samples: the queue is written at the strike's line. The first
  # note's instrument is some thirty writes, which the sound processor takes a sample each to make, so
  # a note before the rest puts it in place first and is not measured.
  def test_a_game_playing_a_recording_strikes_its_wave_notes_on_their_lines
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, plays: :sine, recording: true, lead_in: true)
  end

  # A note struck part way through a frame on a voice still sounding the note before, the new one
  # wobbling or fading from its first frame: the frame's end moves the voice's pitch or loudness for
  # it before the strike comes. The note before keeps its own until the strike: the sound is the
  # same as the same notes without the wobble or the fade until then. Where the strike comes is where
  # the sound first parts from the note before alone, ended by a rest at that tick. A last note
  # wobbling or fading too is in all three, so the frame's end writes the voice in all three alike.
  FIRST = Note.new(at: 0, key: :E5, length: 3, volume: 15)

  private def samples_of_notes(*notes)
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 12, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: notes)])
    cartridge = VBlank.build("STRIKES", console: :genesis, out: nil, err: nil) do
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
    last = Note.new(at: 11, key: :C5, length: 1, volume: 10, **second)
    alone = samples_of_notes(FIRST, last)
    plain = samples_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 8, volume: 10), last)
    changed = samples_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 8, volume: 10, **second), last)
    struck = alone.zip(plain).index { |was, now| was != now }
    apart = plain.zip(changed).index { |was, now| was != now }

    assert_operator apart, :>=, struck, "the note before changed at pair #{apart}, before the strike at #{struck}"
  end

  def test_a_wobble_stepped_before_its_note_is_struck_waits_for_the_strike
    assert_unchanged_until_struck(vibrato: { depth: 15, speed: 1, after: 0 })
  end

  def test_a_fade_stepped_before_its_note_is_struck_waits_for_the_strike
    assert_unchanged_until_struck(decay: 1)
  end

  # The checked run holds the sound chips to the interpreter's log at every pass, those whose notes are
  # still listed to be struck among them: it reads the chips as those writes leave them. One pass of
  # the game takes several frames as the effect plays, and the passes after it end while the notes of
  # the frames it took are still listed.
  def test_the_checked_run_reads_the_chips_at_every_pass_while_notes_wait_to_be_struck
    frames = PLAYED_ON + 30
    slow_once = { rate: 50, apart: 3, lasting: 1, work: SLOW_WORK * 4, work_on: PLAYED_ON + 1 }
    run = VBlank::IR::Backends::Genesis::CheckedRun.new.run(game_program(**slow_once), frames: frames)
    quiet = VBlank::IR::Backends::Genesis::CheckedRun.new.run(game_program(**slow_once, played_on: frames * 2), frames: frames)

    assert_equal quiet.chip_reads.size, run.chip_reads.size
  end

  # The game's own sound over the effect (EffectStrikesHeard), within half a frame of where it is
  # heard with the effect at the frame's start: the PSG takes a new length of wave as the wave it is
  # counting ends (SN76489 data sheet), up to a half wave of the effect's low note later, some 0.23 of
  # a frame; and the frame's music, played before the game's pass, lists four ticks' writes where the
  # other plays them, which takes the pass some thirty lines longer to reach. Folded into the strike,
  # the game's sound is heard most of a frame late, or not at all.
  GAME_SOUND_NEAR = Rational(1, 2)

  def test_the_games_beep_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:genesis, :beep, near: GAME_SOUND_NEAR)
  end

  def test_the_games_wave_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:genesis, :wave, near: GAME_SOUND_NEAR)
  end

  def test_the_tune_taking_back_a_voice_the_effect_lets_go_is_heard_on
    assert_tune_heard_after_effect_lets_go(:genesis)
  end

  # The checked run lays the listed writes over the chips, and leaves out the game's wave's dropped ones,
  # which strike nothing: laid over, the effect's FM writes would stand where the game's wave is.
  def test_the_checked_run_leaves_out_writes_the_games_sound_dropped
    VBlank::IR::Backends::Genesis::CheckedRun.new.run(game_sound_program(:genesis, :wave), frames: FRAMES_PAST_GAME_SOUND)
  end

  FRAMES_PAST_GAME_SOUND = SOUNDED_ON + 6
end
