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

  # Five strikes three and two ticks apart, at 50 ticks a second, each at a volume of its own so the
  # voice says which it is on.
  private def program
    effect = Score.new(tempo: 125, ticks_per_beat: 24, length: 20, plays_once: true, on_timer: true,
                       parts: [Part.new(notes: [15, 13, 11, 9, 7].zip([0, 3, 5, 8, 10]).map { |volume, at| Note.new(at: at, key: :A5, volume: volume) })])
    b = Builder.new
    # Nothing to paint as it sets up, so its first pass takes one frame on the cartridge as on the
    # interpreter, and the timer, which counts from power-on, is at the same place on both.
    b.instance_eval do
      screen :bitmap
      enable_sound
      list = sound_effects :sfx, { chime: effect }
      count = var(:count, 0)
      game_loop do
        list.play :chime if count == 7
        count.store! count + 1
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  # The frames apart the voice's volume changes, in the emulator.
  private def cartridge_gaps(game)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "timer.gba")
      assemble_rom(game, name: "TIMER").write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      pitches = Array.new(FRAMES) do
        probe.step(1)
        (probe.read32(VOICE) & 0xFFFF) >> 12
      end
      probe.close
      changes = pitches.each_cons(2).each_with_index.filter_map { |(a, b), frame| frame if a != b && b.positive? }
      changes.each_cons(2).map { |a, b| b - a }
    end
  end

  # ...and on the interpreter, from its log.
  private def interpreter_gaps(game)
    frames = []
    logged = 0
    run = Reference.new
    run.each_vblank do |frame|
      frames << frame if run.audio.drop(logged).any? { |entry| entry.first == :note && entry[1] == :"sfx.chime" && entry[2].positive? }
      logged = run.audio.size
    end
    run.run(game, frames: FRAMES)
    frames.each_cons(2).map { |a, b| b - a }
  end

  def test_the_notes_are_as_many_frames_apart_as_on_the_interpreter
    game = program
    gaps = interpreter_gaps(game)

    assert_equal 4, gaps.size
    assert_equal gaps, cartridge_gaps(game)
  end
end
