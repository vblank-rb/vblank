# frozen_string_literal: true

require "test_helper"
require "equal_recording_games"

# ONE RECORDING PLAYED WITH SEVERAL ENVELOPES IS KEPT ONCE. An instrument is a recording and one
# envelope, so a recording a game shapes three ways is three instruments. The sound unit keeps a
# recording as its samples alone (its pitch and its envelope are a voice's registers, written for
# each note), so the three read one copy: once in the cartridge, once in the sound unit's memory,
# with each voice still told its own envelope bytes.
class TestSNESEqualRecordings < Minitest::Test
  include EqualRecordingGames

  SNES = VBlank::IR::Backends::SNES
  SNESEnvelope = VBlank::Audio::SNESEnvelope
  Score = VBlank::Audio::Score

  # A voice's registers, counted from its first.
  PITCH = 0x2
  SOURCE = 0x4
  ADSR1 = 0x5

  # A second of sound at 8000 samples a second, longer than the notes below hold.
  LONG = EqualRecordingGames.rising_tone(8000).freeze
  LONG_NEARLY = LONG.dup.tap { |samples| samples[4000] = -samples[4000] - 1 }.freeze

  SHAPES = { soft: SNESEnvelope.new(adsr1: 0xB5, adsr2: 0x60),
             sharp: SNESEnvelope.new(adsr1: 0xDF, adsr2: 0x94),
             swell: SNESEnvelope.new(adsr1: 0x35, adsr2: 0x47, gain: 0xCA) }.freeze

  NOTE_FRAMES = 40

  # A game of three instruments, :soft, :sharp and :swell, each shaped by its own envelope of
  # SHAPES, whose song plays a note of each at once. +recordings+ is each one's samples and rate
  # ({ pcm:, rate: }), LONG at 8000 for one it leaves out.
  private def three_instruments_game(recordings = {})
    parts = SHAPES.keys.map { |name| Score::Part.new(plays: name, notes: [Score::Note.new(at: 0, key: :C4, length: NOTE_FRAMES)]) }
    tune = Score.new(tempo: 150, length: 90, plays_once: true, parts: parts)
    b = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      screen :bitmap
      enable_sound
      SHAPES.each do |name, shape|
        instrument name, **{ pcm: LONG, rate: 8000 }.merge(recordings.fetch(name, {})), note: :C4, envelope: shape
      end
      music = songs :music, [tune]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The recording as the sound unit keeps it, played through once.
  private def kept(samples) = SNES::Samples.recording(samples.pack("c*"), 0).first.pack("C*")

  # The registers of each voice the game's three notes play on, in the parts' order, 10 frames in.
  private def voices_of(run, program)
    SNES::Music.recording_voices(program).first(3).map { |voice| run.dsp_registers.byteslice(voice << 4, 16).bytes }
  end

  def test_three_instruments_of_one_recording_keep_it_once_in_the_cartridge_and_in_sound_memory
    program = three_instruments_game
    run = SNES::CheckedRun.new.run(program, frames: 10)

    assert_equal 1, copies_held(run.rom.bytes, kept(LONG)), "in the cartridge"
    assert_equal 1, copies_held(run.apu_ram, kept(LONG)), "in the sound unit's memory"
    assert_equal 1, voices_of(run, program).map { |registers| registers[SOURCE] }.uniq.size, "and every voice reads it"
  end

  def test_each_voice_is_still_told_its_own_envelope_bytes
    program = three_instruments_game
    run = SNES::CheckedRun.new.run(program, frames: 10)

    assert_equal [[0xB5, 0x60, 0x00], [0xDF, 0x94, 0x00], [0x35, 0x47, 0xCA]], voices_of(run, program).map { |registers| registers[ADSR1, 3] }
    assert_equal %i[soft sharp swell], run.active_samples, "and each sounds under its own name, as on the interpreter"
  end

  def test_recordings_one_sample_apart_are_kept_apart
    program = three_instruments_game(sharp: { pcm: LONG_NEARLY })
    run = SNES::CheckedRun.new.run(program, frames: 10)
    sources = voices_of(run, program).map { |registers| registers[SOURCE] }

    assert_equal [1, 1], [copies_held(run.apu_ram, kept(LONG)), copies_held(run.apu_ram, kept(LONG_NEARLY))]
    assert_equal sources[0], sources[2]
    refute_equal sources[0], sources[1]
  end

  # The rate a recording was made at is no part of what the sound unit keeps: it is the pitch its
  # voice is told. So two rates read one copy, each at its own pitch.
  def test_one_recording_at_two_rates_is_kept_once_and_read_at_each_rate
    program = three_instruments_game(sharp: { rate: 16_000 })
    run = SNES::CheckedRun.new.run(program, frames: 10)
    soft, sharp, = voices_of(run, program)

    assert_equal 1, copies_held(run.apu_ram, kept(LONG))
    assert_equal soft[SOURCE], sharp[SOURCE]
    assert_equal 2 * (soft[PITCH] | (soft[PITCH + 1] << 8)), sharp[PITCH] | (sharp[PITCH + 1] << 8)
  end

  # The game's own plays, too: three recordings alike, each played, read one copy.
  def test_the_games_own_plays_of_recordings_alike_read_one_copy
    program = recordings_game(plays: %i[first second third], console: :snes)
    run = SNES::CheckedRun.new.run(program, frames: 6)
    kept_looping = SNES::Samples.recording(RECORDING.pack("c*"), RECORDING.size).first.pack("C*")

    assert_equal 1, copies_held(run.apu_ram, kept_looping)
    assert_equal %i[first second third], run.active_samples
  end
end
