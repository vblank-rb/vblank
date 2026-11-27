# frozen_string_literal: true

require "test_helper"

# A game describes how its original's sound driver keeps time (`sound_driver`), and a request can say
# the screen row it is sent at (`sent_after_rows:`). The Super Nintendo is the console whose rows a
# request counts, from the start of its vertical blank.
#
# The answer key is the driver's wakes in real time: the sound unit's timer wakes the driver
# 8000/96 times a second on a clock that runs 32040/32000 fast (the SNESdev wiki, "S-SMP"; bsnes
# apuFrequency), wake k at k over that rate from power-on, each in the frame its time falls in. Each
# wake adds the driver's tempo step, a 16-bit count, and a tick is where the count comes round. A
# frame begins where the vertical blank does, and the pass that asks runs in the frame its own end
# takes the request up in, so a request sent at a row is that many rows into that frame: the driver
# picks it up on the first wake past it. A driver that keys an effect only on a tick starts it on the
# first wake from there that holds one.
#
# Each game is played by the run's own player, which holds it to the interpreter frame by frame, and
# what was heard is read from the interpreter's log.
class TestSoundDriverOnTheSuperNintendo < Minitest::Test
  Score = VBlank::Audio::Score

  WAKES = Rational(8000, 0x60) # the driver's wakes a second, as it names them
  SOUND_UNIT = Rational(32_040, 32_000) # how much faster the sound unit's clock runs than named
  TICK_RATE = 50 # the effects' ticks a second: a tempo of 125 at 24 ticks a beat
  LINE_CYCLES = 1364 # a screen row, in the console's master clock (fullsnes)
  FRAMES = 160
  FIRST_PITCHES = [880, 659].freeze # the first notes of :a and :b, A5 and E5
  SONG_ROWS = [0, 60, 120, 180, 240].freeze

  private def effect(key)
    notes = [Score::Note.new(at: 0, key: key), Score::Note.new(at: 1, key: :C4), Score::Note.new(at: 2, key: :D4)]
    Score.new(tempo: 125, ticks_per_beat: 24, length: 4, plays_once: true, parts: [Score::Part.new(notes: notes)])
  end

  # The game: the driver described by +driver+, and on each pass whose count is a key of +asks+, the
  # effects that pass asks for, each [name, row or nil]. With +song_on+, [count, row], the pass of that count
  # names a quiet tune at that row; with +silent_on+ the music volume goes to 0 on that pass.
  private def game(asks, song_on: nil, silent_on: nil, **driver)
    b = Builder.new
    effects = { a: effect(:A5), b: effect(:E5) }
    tune = Score.new(tempo: 150, length: 96, parts: [Score::Part.new(plays: :noise, notes: [Score::Note.new(at: 0, key: :C4)])])
    b.instance_eval do
      screen :bitmap
      enable_sound
      sound_driver interrupts_per_second: WAKES, **driver
      list = sound_effects :sfx, effects
      music = songs(:music, [tune]) if song_on
      count = var(:count, 0)
      game_loop do
        music.play 0, sent_after_rows: song_on.last if song_on && count == song_on.first
        music_volume 0 if silent_on && count == silent_on
        asks.each do |on, requests|
          requests.each { |name, row| list.play name, sent_after_rows: row if count == on }
        end
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program.copy.tap { |program| program.console = :snes }
  end

  # +program+ played by the run's player, which fails at the first frame it and the interpreter differ.
  private def play_checked(program)
    skip_on_snes "the cartridge does not play a sound driver's habits or a request's row yet"
    VBlank::Testing::BuildChecks.without_checks { game_player.run(program, frames: FRAMES) }
  end

  # The frame of each effect's first note, as the interpreter's log has it: { name => [frames] }.
  private def first_notes(program)
    player = Reference.new
    started = Hash.new { |hash, name| hash[name] = [] }
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each do |entry|
        next unless entry.first == :note && FIRST_PITCHES.include?(entry[2].round)

        started[entry[1]] << frame
      end
      logged = player.audio.size
    end
    player.run(program, frames: FRAMES)
    started
  end

  # The frame of each note effect :a sounds, as the interpreter's log has it.
  private def note_frames(program)
    player = Reference.new
    frames = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| frames << frame if entry.first == :note && entry[1] == :"sfx.a" && entry[2].positive? }
      logged = player.audio.size
    end
    player.run(program, frames: FRAMES)
    frames
  end

  # Every wake through FRAMES, as [time, frame, holds a tick], frames counted from 1: the key above.
  # With +reset_after+, [time, share], the count is set to the share on the first wake past that time, and
  # counted at it until it comes round, as a song's start sets it; with +silent_from+, no wake from that
  # time adds anything.
  private def wakes(reset_after: nil, silent_from: nil)
    frame_seconds = VBlank::Console::SUPER_NINTENDO.frame_seconds
    rate = WAKES * SOUND_UNIT
    step = (Rational(TICK_RATE) / WAKES * 65_536).floor # the driver's own tempo add, read from it
    count = 0
    until_tick = 0
    (1..).lazy.map { |k| Rational(k) / rate }.take_while { |time| time <= FRAMES * frame_seconds }.map do |time|
      if reset_after && time > reset_after.first
        count = until_tick = reset_after.last
        reset_after = nil
      end
      added = silent_from && time > silent_from ? 0 : until_tick.nonzero? || step
      count += added
      ticked = count >= 65_536 && added.positive?
      until_tick = 0 if ticked
      count %= 65_536
      [time, (time / frame_seconds).ceil, ticked]
    end.to_a
  end

  # The frame a request sent at +row+ in the pass whose count is +on+ sounds its first note on: on the
  # first wake past the row in that pass's frame, or with +on_tick+ the first such wake holding a tick.
  private def predicted(on, row, on_tick:, **counting)
    wakes(**counting).find { |time, _, ticked| time > sent_at(on, row) && (ticked || !on_tick) }&.at(1)
  end

  # When a request sent at +row+ in the pass whose count is +on+ is sent, in seconds from power-on.
  private def sent_at(on, row)
    frame_seconds = VBlank::Console::SUPER_NINTENDO.frame_seconds
    ((on + 1) * frame_seconds) + (Rational(row) * LINE_CYCLES / VBlank::Console::SUPER_NINTENDO.cycles_a_second)
  end

  def test_two_effects_at_different_rows_each_start_on_the_tick_their_row_predicts
    program = game({ 40 => [[:a, 10]], 80 => [[:b, 200]] }, effects_start: :on_next_tick)
    play_checked(program)
    heard = first_notes(program)

    assert_equal [predicted(40, 10, on_tick: true)], heard[:"sfx.a"]
    assert_equal [predicted(80, 200, on_tick: true)], heard[:"sfx.b"]
  end

  # A late row puts some starts on a later tick than the frame's first wake would. Each pass is
  # checked against the key; the run's player plays the passes where the row moves the start.
  def test_a_row_moves_the_start_off_the_frames_first_wake
    starts = (30..70).map do |on|
      program = game({ on => [[:a, 200]] }, effects_start: :on_next_tick)
      at_row = predicted(on, 200, on_tick: true)
      at_once = predicted(on, 0, on_tick: true)
      [program, first_notes(program)[:"sfx.a"].first, at_row, at_once]
    end

    starts.each { |_, heard, at_row, _| assert_equal at_row, heard }
    moved = starts.reject { |_, _, at_row, at_once| at_row == at_once }
    refute_empty moved, "a late row puts some start on a later tick"
    moved.first(2).each { |program, *| play_checked(program) }
  end

  # An effect not keyed on a tick starts on the first wake past its row, part way through the frame:
  # the frame's later wakes hold its first notes where the frame's first would have held them all.
  def test_a_row_starts_an_effect_on_the_wake_past_it
    program = game({ 40 => [[:a, 200]], 80 => [[:b, 10]] })
    play_checked(program)
    heard = first_notes(program)

    assert_equal [predicted(40, 200, on_tick: false)], heard[:"sfx.a"]
    assert_equal [predicted(80, 10, on_tick: false)], heard[:"sfx.b"]
  end

  # Two requests sent before one wake: the driver reads the port once, and hears the last.
  def test_of_two_requests_before_one_wake_the_last_sent_is_heard
    program = game({ 40 => [[:a, 4], [:b, 6]] })
    play_checked(program)
    heard = first_notes(program)

    assert_empty heard[:"sfx.a"]
    assert_equal 1, heard[:"sfx.b"].size
  end

  # A song named at a row sets the count on the first wake past the row (`tick_count_at_song_start:`), and
  # an effect keyed on a tick starts on the beat that count gives. The run's player plays a row of each
  # beat the row gives.
  def test_a_song_named_at_a_row_sets_the_count_on_the_wake_past_it
    played = {}
    moved = (30..37).map do |song_on|
      keys = SONG_ROWS.map do |row|
        program = game({ song_on + 10 => [[:a, nil]] }, song_on: [song_on, row], effects_start: :on_next_tick,
                                                        tick_count_at_song_start: 255 / 256r)
        ticks = wakes(reset_after: [sent_at(song_on, row), 0xFF00]).select { |time, _, ticked| ticked && time > sent_at(song_on + 10, 0) }
        key = ticks.first(3).map { |_, frame, _| frame }

        assert_equal key, note_frames(program), "song on #{song_on}, row #{row}"
        played[key] ||= program
        key
      end
      keys.uniq.size > 1
    end
    assert moved.any?, "where the song is named moves the beat"
    played.values.first(3).each { |program| play_checked(program) }
  end

  # While the music is silent the driver skips its tick, so an effect keyed on one waits for the music.
  def test_silent_music_stops_the_ticks
    asks = { 60 => [[:a, nil]] }
    silent = game(asks, silent_on: 10, effects_start: :on_next_tick, silent_music_stops_ticks: true)
    plain = game(asks, silent_on: 10, effects_start: :on_next_tick)
    play_checked(silent)
    play_checked(plain)

    assert_empty first_notes(silent)[:"sfx.a"]
    assert_equal 1, first_notes(plain)[:"sfx.a"].size
  end
end
