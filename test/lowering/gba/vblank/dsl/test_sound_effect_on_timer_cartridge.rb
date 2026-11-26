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
  private def program(tempo: 125, ticks_per_beat: 24, asked_on: 7)
    notes = VOLUMES.zip([0, 3, 5, 8, 10]).map { |volume, at| Note.new(at: at, key: :A5, volume: volume) }
    effect = Score.new(tempo: tempo, ticks_per_beat: ticks_per_beat, length: 20, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: notes)])
    b = Builder.new
    # Nothing to paint as it sets up, so its first pass takes one frame on the cartridge as on the
    # interpreter, and the timer, which counts from power-on, is at the same place on both.
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: effect }
      count = var(:count, 0)
      game_loop do
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
end
