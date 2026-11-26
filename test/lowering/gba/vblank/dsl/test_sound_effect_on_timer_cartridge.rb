# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A sound effect on a timer, on the Advance's own cartridge: the frames its notes start on, read
# from the first square voice's volume in the emulator, held to the interpreter's. What every run
# plays is in test/all/vblank/builder/test_sound_effect_on_timer.rb.
class TestSoundEffectOnTimerCartridge < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  VOICE = VBlank::Console::Hardware::REG_SOUND1CNT_H
  FRAMES = 60
  VOLUMES = [15, 13, 11, 9, 7].freeze

  # Five strikes three and two ticks apart, each at a volume of its own so the voice says which it
  # is on: at 50 ticks a second by default, asked for on the pass counted +asked_on+.
  private def program(tempo: 125, ticks_per_beat: 24, asked_on: 7, interrupts: nil, song_on: nil, song_now: false, **counts)
    notes = VOLUMES.zip([0, 3, 5, 8, 10]).map { |volume, at| Note.new(at: at, key: :A5, volume: volume) }
    effect = Score.new(tempo: tempo, ticks_per_beat: ticks_per_beat, length: 20, plays_once: true, on_timer: true,
                       interrupts_per_second: interrupts, **counts, parts: [Part.new(notes: notes)])
    tune = Score.new(tempo: 150, length: 96, parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: :C4)])])
    b = Builder.new
    # Nothing to paint as it sets up, so its first pass takes one frame on the cartridge as on the
    # interpreter, and the timer, which counts from power-on, is at the same place on both.
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: effect }
      tunes = songs(:music, [tune]) if song_on
      count = var(:count, 0)
      game_loop do
        tunes.play 0, this_frame: song_now if song_on && count == song_on
        list.play :chime if count == asked_on
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # The volume the voice is left at as each frame ends, from the frame it first sounds: in the
  # emulator...
  private def cartridge_volumes(game)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "timer.gba")
      assemble_rom(game, name: "TIMER").write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      volumes = Array.new(FRAMES) do
        probe.step(1)
        (probe.read32(VOICE) & 0xFFFF) >> 12
      end
      probe.close
      volumes
    end
  end

  # ...and on the interpreter, from the last of each frame's settings of the voice in its log.
  private def interpreter_volumes(game)
    volumes = []
    logged = 0
    run = Reference.new
    run.each_vblank do
      set = run.audio.drop(logged).select { |entry| entry.first == :voice && entry[2] == :"sfx.chime" }
      volumes << (set.empty? ? volumes.last || 0 : set.last[4])
      logged = run.audio.size
    end
    run.run(game, frames: FRAMES)
    volumes
  end

  # Where the voice's volume changes to a note's, as [frames since the last change, the volume].
  private def changes(volumes)
    volumes.drop_while(&:zero?).each_with_index.chunk_while { |(a, _), (b, _)| a == b }.map { |run| [run.first.last, run.first.first] }
           .each_cons(2).map { |(was, _), (now, volume)| [now - was, volume] }.select { |_, volume| volume.positive? }
  end

  def test_the_notes_are_as_many_frames_apart_as_on_the_interpreter
    game = program
    heard = changes(interpreter_volumes(game))

    assert_equal 4, heard.size
    assert_equal heard, changes(cartridge_volumes(game))
  end

  # At 50 ticks a second every sixth frame holds no tick, and the pass counted 5 is taken up on one:
  # the effect starts there at once, a frame before the timer's next tick, as on the interpreter. The
  # voice is read a frame later on the cartridge than in the interpreter's log, as the pass counted 7
  # shows, whose frame holds a tick.
  def test_an_effect_asked_for_on_a_frame_without_a_tick_starts_there
    game = program(asked_on: 5)
    expected = interpreter_volumes(game)
    got = cartridge_volumes(game)
    lag = cartridge_volumes(program).index(&:positive?) - interpreter_volumes(program).index(&:positive?)

    assert_equal 4, changes(expected).size
    assert_equal expected.index(&:positive?) + lag, got.index(&:positive?), "the frame the first note sounds on"
    assert_equal changes(expected), changes(got)
  end

  # At 240 ticks a second a frame holds four or five ticks, and two notes can fall in one: the voice
  # is left at the second, as on the interpreter.
  def test_a_timer_faster_than_the_frames_leaves_the_voice_where_the_interpreter_does
    game = program(tempo: 150, ticks_per_beat: 96)
    heard = changes(interpreter_volumes(game))

    assert_operator heard.size, :<, VOLUMES.size - 1, "two notes share a frame"
    assert_equal heard, changes(cartridge_volumes(game))
  end
  # On a driver's own interrupt, 83 and a third a second, a frame holds one or two interrupts and a
  # tick falls on some of them: the notes are as many frames apart as on the interpreter wherever the
  # effect is asked for.
  def test_on_a_drivers_interrupt_the_notes_are_as_many_frames_apart_as_on_the_interpreter
    [5, 6, 7, 8].each do |asked_on|
      game = program(asked_on: asked_on, interrupts: Rational(8000, 0x60))
      heard = changes(interpreter_volumes(game))

      assert_equal 4, heard.size, "asked on #{asked_on}"
      assert_equal heard, changes(cartridge_volumes(game)), "asked on #{asked_on}"
    end
  end

  # Where a tune's start sets the tempo count, or the tune's own tempo counting it, moves the beats;
  # the cartridge's follow the interpreter's.
  COUNTED_ASKS = [5, 6].freeze # Passes the effect is asked on, a frame apart

  # A tune started where the game asks (`this_frame: true`) sets the count as one taken up at the
  # next frame does.
  def test_a_tune_started_this_frame_sets_the_tick_count_as_on_the_interpreter
    COUNTED_ASKS.each do |asked_on|
      game = program(asked_on: asked_on, interrupts: Rational(8000, 0x60), song_on: 3, song_now: true, tick_count_at_song_start: 1/2r)
      unset = program(asked_on: asked_on, interrupts: Rational(8000, 0x60), song_on: 3, song_now: true)

      refute_equal changes(interpreter_volumes(unset)), changes(interpreter_volumes(game)), "the start moves the beats, asked on #{asked_on}"
      assert_equal changes(interpreter_volumes(game)), changes(cartridge_volumes(game)), "asked on #{asked_on}"
    end
  end

  def test_the_tick_count_moves_the_beats_as_on_the_interpreter
    { { tick_count_at_song_start: 255/256r } => 3, { on_tune_tempo: true } => 3,
      { on_tune_tempo: true, tick_count_at_song_start: 255/256r } => 3 }.each do |counts, song_on|
      COUNTED_ASKS.each do |asked_on|
        game = program(asked_on: asked_on, interrupts: Rational(8000, 0x60), song_on: song_on, **counts)
        heard = changes(interpreter_volumes(game))

        assert_equal 4, heard.size, "#{counts} asked on #{asked_on}"
        assert_equal heard, changes(cartridge_volumes(game)), "#{counts} asked on #{asked_on}"
      end
    end
  end

  # ...and on one of 300 a second, with 160 ticks a second counted on it, a frame holds five
  # interrupts and two or three ticks.
  def test_on_a_fast_interrupt_the_voice_is_left_where_the_interpreter_leaves_it
    [5, 7].each do |asked_on|
      game = program(tempo: 100, ticks_per_beat: 96, asked_on: asked_on, interrupts: 300)

      assert_equal changes(interpreter_volumes(game)), changes(cartridge_volumes(game)), "asked on #{asked_on}"
    end
  end
end
