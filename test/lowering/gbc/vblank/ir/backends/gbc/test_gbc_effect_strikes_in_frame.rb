# frozen_string_literal: true

require "test_helper"
require "effect_strikes_heard"

# A sound effect on a timer, struck inside the frame on the Color (GBC Runtime::Strikes). Its notes
# are as far apart in time as their ticks, not rounded to the frames they fall in: a tick of 50 a
# second is a frame and a fifth, so notes three ticks apart are 60 milliseconds apart, where frames
# would put them three or four frames apart, 50 or 67. Each note's register writes wait on a list
# for their line of the screen, and the timer's interrupt writes them (Pan Docs, "Timer and Divider
# Registers").
#
# Measured in the emulator's sound: where each note is first heard, rising out of the silence the
# one before it left, in frames from power-on: the frame whose sound holds it, and how far through
# that frame's sample pairs it is.
class TestGBCEffectStrikesInFrame < Minitest::Test
  include EffectStrikesHeard

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  HEARD_ABOVE = 1000 # well under a note, and above the voice ringing as it falls quiet after a rest
  SILENCE = 120 # pairs no louder than that in a row: longer than any wave of the note passing nought
  PLAYED_ON = 10
  FRAMES = 120
  # Within a millisecond and a half of the tick's own time. A line is some 109 microseconds and the
  # timer's count some 122, and fourteen notes in a row measured here lie within a millisecond of
  # one another against their ticks: a strike that comes while interrupts are held off, as the
  # sprite table is copied in the blank, waits for them. Frames would put a note out by a fifth of a
  # frame or more, 3 milliseconds.
  NEAR_SECONDS = Rational(3, 2000)
  # The pass of a game that does this much work in each takes two frames or more (the test checks).
  SLOW_WORK = 3000

  # +notes+ notes +apart+ ticks apart, each +lasting+ ticks then a rest, at +rate+ ticks a second.
  # With +work+ each pass of the game counts that high first. The effect plays on pass +played_on+.
  # With +recording+ a silent recording loops from the second pass, and holds the timer. With +bar+ a
  # status bar covers the sprites from BAR_TOP down, a white sprite across its top. With +bend+ the
  # background's rows are bent, so the display's interrupt comes at the end of every line.
  private def game(rate:, apart:, lasting:, notes: 5, work: 0, recording: false, bar: false, bend: false)
    VBlank.build("STRIKES", console: :gbc, out: nil, err: nil,
                 &game_code(rate: rate, apart: apart, lasting: lasting, notes: notes, work: work, recording: recording, bar: bar,
                            bend: bend))
  end

  BAR_TOP = 128

  private def game_code(rate:, apart:, lasting:, notes: 5, work: 0, recording: false, bar: false, bend: false)
    struck = (0...notes).map { |n| Note.new(at: n * apart, key: :E5, length: lasting) }
    effect = Score.new(tempo: rate, ticks_per_beat: 60, length: notes * apart, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: struck)])
    test = self
    proc do
      test.covering_bar(self, bar: bar, bend: bend) if bar || bend
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      busy = var :busy, 0
      # At a low rate: a bent screen and a recording at the usual rate leave a pass little of its frame.
      quiet = (sample :quiet, pcm: Array.new(2000, 0), rate: 2048 if recording)
      game_loop do
        pass += 1
        quiet.play(loop: true) if recording && pass == 2
        sfx.play :chime if pass == PLAYED_ON
        repeat(work) { busy += 1 } if work.positive?
      end
    end
  end

  # A green status bar from BAR_TOP down that covers the sprites (with +bar+), over a red field (its rows
  # bent with +bend+), and a white sprite half over it, in the game +game+ (test_gbc_bar_covers_sprites.rb's).
  def covering_bar(game, bar:, bend:)
    game.instance_eval do
      screen :tiled
      image(:red_art, "#" => :red, "." => :blue) { bend ? (["#..#...."] * 8).join("\n") : Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      image(:ball, "#" => :white) { Minitest::Test::SOLID_TILE }
      tiles :field_tiles, "#" => :red_art
      tiles :bar_tiles, "#" => :green_art
      field = background :field, tiles: :field_tiles, map: Array.new(32) { "#" * 32 }
      field.scroll_each_row { |row| row & 3 } if bend
      if bar
        covering = status_bar :score, tiles: :bar_tiles, map: ["#" * 32, "#" * 32], top: TestGBCEffectStrikesInFrame::BAR_TOP
        covering.covers_sprites = true
      end
      sprite :ball, at: [40, TestGBCEffectStrikesInFrame::BAR_TOP - 4]
    end
  end

  Heard = Data.define(:onsets, :passes)

  # The frame, with the share of it gone by, each note is first heard at, and how many passes the
  # game played. The sound switching on at power-on is heard first, and is not a note.
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

  private def assert_struck_apart(rate:, apart:, lasting:, notes: 5, **)
    sound = heard(game(rate: rate, apart: apart, lasting: lasting, notes: notes, **))
    yield sound if block_given?
    frame_seconds = VBlank::Console::COLOR.frame_seconds
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
  # frames apart, so each is heard alone.
  def test_notes_on_later_ticks_of_a_frame_are_struck_at_their_own_ticks
    assert_struck_apart(rate: 240, apart: 10, lasting: 3)
  end

  # A game whose pass takes several frames plays their music one after the other as its wait comes:
  # each frame's notes are struck a frame after the one before's, their ticks apart from when they
  # are listed, not all at once because the lines of the frames they fell in have gone by.
  def test_a_game_slower_than_the_frames_strikes_its_notes_as_far_apart_as_their_ticks
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, notes: 8, work: SLOW_WORK) do |sound|
      assert_operator sound.passes, :<=, FRAMES / 2, "every pass takes two frames or more"
    end
  end

  # A game that plays a recording plays it on the timer, so the strikes wait for their lines on the
  # display's line match instead (Pan Docs, "LCD Status Registers").
  def test_a_game_playing_a_recording_strikes_its_notes_on_their_lines
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, recording: true)
  end

  # A game whose status bar covers the sprites has the display's line match switch the sprites off at
  # the bar's top, and the strikes share it: the line match is set for whichever comes first.
  def test_a_game_playing_a_recording_under_a_bar_over_its_sprites_strikes_its_notes_on_their_lines
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, recording: true, bar: true)
  end

  # A screen with bent rows has the display's interrupt at the end of every line, which the line match
  # shares: the strikes are answered on the line it names, and each line's bend goes on.
  def test_a_game_playing_a_recording_on_a_bent_screen_strikes_its_notes_on_their_lines
    assert_struck_apart(rate: 50, apart: 3, lasting: 1, recording: true, bend: true)
    assert_struck_apart(rate: 240, apart: 10, lasting: 3, recording: true, bend: true)
  end

  # The bends themselves: the field's columns stand where each row's bend puts them, on every frame
  # while notes are struck.
  def test_a_bent_screen_keeps_its_bends_while_notes_are_struck_on_the_line_match
    reader = VBlank::Diagnostics::Verifier.new(game(rate: 240, apart: 2, lasting: 1, notes: 40, recording: true, bend: true), frames: 0)
    rows = lambda do
      reader.step(1)
      (0...144).step(9).map { |y| (0...8).map { |x| reader.pixel_gba(x, y) } }
    end
    (PLAYED_ON - 3).times { rows.call }
    bent = rows.call
    frames = Array.new(20) { rows.call == bent }

    refute_equal 1, bent.uniq.size, "the rows are bent, each its own way"
    assert_equal [true], frames.uniq, "the bent rows alike on each frame: #{frames.inspect}"
  ensure
    reader&.close
  end

  # ...and the bar still covers the sprites on every frame while the notes are struck, from its top
  # line exactly: a strike due just before the bar's line waits for the bar.
  def test_a_bar_over_the_sprites_covers_them_while_notes_are_struck_on_the_line_match
    white = 0x7FFF
    green = VBlank::Graphics::Color.resolve(:green)
    reader = VBlank::Diagnostics::Verifier.new(game(rate: 240, apart: 2, lasting: 1, notes: 40, recording: true, bar: true), frames: 0)
    cut = Array.new(PLAYED_ON + 20) do
      reader.step(1)
      reader.pixel_gba(42, BAR_TOP - 1) == white && reader.pixel_gba(42, BAR_TOP) == green
    end

    assert_equal [true], cut.drop(PLAYED_ON - 2).uniq, "the sprite cut at the bar on each frame: #{cut.inspect}"
  ensure
    reader&.close
  end

  # An effect from the left speaker alone over a song on another voice from the right, whose notes set
  # their voice's speakers on the frames the effect's notes wait for their strikes: the song's write
  # of the speakers' switches, which hold every voice's, folds into the effect's listed one, and must
  # change its own voice's switches alone. Heard as how many of the right speaker's samples are louder
  # than the song's quiet drums while the effect plays: not the effect's notes themselves (1683 when
  # the song's write took the effect's switches with it, measured in mGBA).
  RIGHT_LOUD = 4000
  RIGHT_LOUD_MOST = 64

  private def right_speaker_loud_samples(with_effect)
    drums = Score.new(tempo: 150, ticks_per_beat: 4,
                      parts: [Part.new(plays: :noise, pan: :right, notes: (0...8).map { |n| Note.new(at: n, key: :C4, length: 1, volume: 2) })])
    struck = (0...8).map { |n| Note.new(at: n * 3, key: :E5, length: 2, volume: 15) }
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 24, plays_once: true, on_timer: true,
                       parts: [Part.new(pan: :left, notes: struck)])
    cartridge = VBlank.build("STRIKES", console: :gbc, out: nil, err: nil) do
      enable_sound
      music = songs :music, [drums]
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        music.play 0
        sfx.play :chime if with_effect && pass == PLAYED_ON
      end
    end
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    right = []
    (PLAYED_ON + 30).times do |frame|
      reader.step(1)
      right.concat(reader.last_frame_samples.each_slice(2).map { |pair| pair.last.abs }) if frame > PLAYED_ON + 2
    end
    right.count { |loudness| loudness > RIGHT_LOUD }
  ensure
    reader&.close
  end

  def test_a_songs_speaker_write_folded_into_an_effects_keeps_the_effects_speaker
    alone = right_speaker_loud_samples(false)
    over = right_speaker_loud_samples(true)

    assert_operator over, :<=, alone + RIGHT_LOUD_MOST, "the right speaker's loud samples with the effect from the left: #{over}, the song alone: #{alone}"
  end

  # An effect from the left speaker alone, its notes each ended by a rest. A rest sends its voice to
  # both speakers (a rest has no side), and must do so only once the voice is quiet: switched first,
  # the note still sounding is heard from the right for the moment between the two writes, and on a
  # timer the moment is as long as the list takes to reach the voice's write. Heard as how many of the
  # right speaker's samples are loud while the effect plays, on a timer and once a frame.
  private def right_speaker_loud_samples_of_rests(on_timer)
    struck = (0...8).map { |n| Note.new(at: n * 3, key: :E5, length: 2, volume: 15) }
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 24, plays_once: true, on_timer: on_timer,
                       parts: [Part.new(pan: :left, notes: struck)])
    cartridge = VBlank.build("STRIKES", console: :gbc, out: nil, err: nil) do
      enable_sound
      sfx = sound_effects :sfx, { chime: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        sfx.play :chime if pass == PLAYED_ON
      end
    end
    reader = VBlank::Diagnostics::Verifier.new(cartridge, frames: 0)
    right = []
    (PLAYED_ON + 30).times do |frame|
      reader.step(1)
      right.concat(reader.last_frame_samples.each_slice(2).map { |pair| pair.last.abs }) if frame > PLAYED_ON - 2
    end
    right.count { |loudness| loudness > RIGHT_LOUD }
  ensure
    reader&.close
  end

  def test_a_rest_on_a_timer_moves_its_voice_to_both_speakers_after_it_is_quiet
    assert_equal 0, right_speaker_loud_samples_of_rests(true)
  end

  def test_a_rest_once_a_frame_moves_its_voice_to_both_speakers_after_it_is_quiet
    assert_equal 0, right_speaker_loud_samples_of_rests(false)
  end

  # A note struck part way through a frame on a voice still sounding the note before, the new one
  # wobbling or stepping its shape from its first frame: the frame's end moves the voice's pitch or
  # shape for it before the strike comes. Folded into the strike's own listed writes, it does not
  # reach the voice before the strike: until the frame of the strike the writes to the sound chip
  # are those of the same notes without the wobble or the shapes, and on that frame they are the same
  # registers, in the same order, the strike's values carrying the change. A last note wobbling or
  # stepping too is in both, so the frame's end writes the voice in both alike.
  #
  # Read as writes, frame by frame (Verifier#watch_sound), not as sound: two builds of different
  # length strike a note a few cycles apart, which moves its wave by part of a sample.
  FIRST = Note.new(at: 0, key: :E5, length: 3, volume: 15)

  private def writes_of_notes(*notes)
    effect = Score.new(tempo: 50, ticks_per_beat: 60, length: 12, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: notes)])
    cartridge = VBlank.build("STRIKES", console: :gbc, out: nil, err: nil) do
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
    last = Note.new(at: 11, key: :C5, length: 1, volume: 10, **second)
    plain = writes_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 8, volume: 10), last)
    changed = writes_of_notes(FIRST, Note.new(at: 3, key: :A5, length: 8, volume: 10, **second), last)
    struck = plain.zip(writes_of_notes(FIRST, last)).index { |with, without| with != without }

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

  # The game's own beep over the effect (EffectStrikesHeard), within a quarter of a frame of where it
  # is heard with the effect at the frame's start: the square voice takes a new length of wave as the
  # one it is counting ends (Pan Docs, "Audio Details"), up to a half wave of the effect's low note
  # later, and the frame's music lists four ticks' writes before the game's pass, where the other
  # writes them. Left beside the listed strike, the beep is cut off at the strike's line.
  GAME_SOUND_NEAR = Rational(1, 4)

  def test_the_games_beep_before_a_listed_strike_on_its_voice_is_heard_over_it
    assert_game_sound_heard_over_effect(:gbc, :beep, near: GAME_SOUND_NEAR)
  end

  def test_the_tune_taking_back_a_voice_the_effect_lets_go_is_heard_on
    assert_tune_heard_after_effect_lets_go(:gbc)
  end

  # A game of many effects on the timer keeps them in the banks and plays them from rows
  # (Runtime::EffectTable, whose start is rt_sfx_started), which start and move on what was asked for
  # as the routines each effect has of its own do. Forty effects of twelve notes, some asked for while
  # they still sound, checked against the interpreter pass by pass.
  TABLE_EFFECTS = 40
  TABLE_KEYS = %i[C5 E5 G5 B5].freeze

  private def table_game
    effects = Array.new(TABLE_EFFECTS) do |n|
      notes = (0...12).map { |k| Note.new(at: k * 2, key: TABLE_KEYS[(n + k) % TABLE_KEYS.size], length: 1) }
      [:"e#{n}", Score.new(tempo: 125, ticks_per_beat: 24, length: 24, plays_once: true, on_timer: true, parts: [Part.new(notes: notes)])]
    end.to_h
    proc do
      enable_sound
      list = sound_effects :sfx, effects
      count = var(:count, 0)
      game_loop do
        list.play count % TABLE_EFFECTS if count % 5 == 2
        list.play 0 if count % 7 == 3
        count.store! count + 1
      end
    end
  end

  def test_effects_kept_in_the_banks_start_and_move_on_as_the_interpreter_does
    code = table_game
    built = VBlank.build("TABLE", console: :gbc, out: nil, err: nil, &code)
    builder = Builder.new
    builder.instance_eval(&code)
    builder.finalize_program
    program = builder.program.copy.tap { |copy| copy.console = :gbc }

    assert built.built.code.key?("rt_sfx_started"), "the effects are played from their rows"
    VBlank::IR::Backends::GBC::CheckedRun.new.run(program, frames: 200) # raises where the two part
  end
end
