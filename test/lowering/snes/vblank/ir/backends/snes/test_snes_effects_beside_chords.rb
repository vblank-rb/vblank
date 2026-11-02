# frozen_string_literal: true

require "test_helper"

# A SOUND EFFECT ANSWERS ITS PRESS, even with a song striking chords in a nearly full pass. The sound
# chip is told things through a mailbox, a write at a time, while the game waits for the screen, and
# a chord is a great many writes, so what is asked for after one has a long way to wait in line. An
# effect is a press answered, and goes ahead of it.
class TestSNESEffectsBesideChords < Minitest::Test
  SNES = VBlank::IR::Backends::SNES
  Score = VBlank::Audio::Score
  ROOT = VBlank::Audio::Music::NOTE_FREQUENCIES.fetch(:C4)
  RATE = 32_000 # the chip's own: pitch $1000 reads such a recording as recorded
  EFFECT_PITCH = 0x1964
  ASKED_ON_PASS = 40
  VOICES = 8
  ENVX = 0x8

  private def chords_game(work:, effect_envelope: nil, stops_tune: false)
    b = Builder.new(options: VBlank::Cartridge::Options.new(console: :snes))
    b.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * (RATE / 2), rate: RATE, note: :C4
      chord_notes = (0...96).step(2).map { |tick| Score::Note.new(at: tick, key: :C3) }
      parts = Array.new(7) { Score::Part.new(plays: :tone, envelope: { decay: 0.5, sustain: 0.5 }, notes: chord_notes) }
      music = songs :music, [Score.new(parts: parts, tempo: 150, ticks_per_beat: 4, length: 96)]
      chirp = Score.new(parts: [Score::Part.new(plays: :tone, envelope: effect_envelope,
                                                notes: [Score::Note.new(at: 0, hz: ROOT * EFFECT_PITCH / 4096.0, length: 40)])],
                        tempo: 150, ticks_per_beat: 4)
      sfx = sound_effects :sfx, { chirp: chirp }
      music.play 0
      passes = var :passes, 0
      spent = var :spent, 0
      game_loop do
        passes += 1
        sfx.play 0 if passes == ASKED_ON_PASS
        music.stop if stops_tune && passes == ASKED_ON_PASS
        repeat(work) { spent += 1 }
      end
    end
    b.finalize_program
    b.program
  end

  # The first frame a voice of the chip holds the effect's pitch, and the frame the game asked for it
  # was played.
  private def frames_late(work:)
    run = SNES::HeadlessRun.new
    heard = nil
    asked = nil
    run.each_vblank do |frame|
      asked ||= frame if run[:passes] >= ASKED_ON_PASS
      dsp = run.dsp_registers
      next unless dsp

      heard ||= frame if (0...VOICES).any? { |voice| dsp.getbyte((voice << 4) + 2) | (dsp.getbyte((voice << 4) + 3) << 8) == EFFECT_PITCH }
    end
    run.run(chords_game(work: work), frames: (ASKED_ON_PASS * 2) + 30)
    assert heard, "the effect never reached the chip"
    heard - asked
  end

  def test_an_effect_goes_ahead_of_a_chord
    assert_operator frames_late(work: 300), :<=, 3
  end

  # The voice holding the effect's pitch, as [its left volume, how loud its envelope is], or nil.
  private def effect_voice(run)
    dsp = run.dsp_registers
    voice = (0...VOICES).find { |v| dsp.getbyte((v << 4) + 2) | (dsp.getbyte((v << 4) + 3) << 8) == EFFECT_PITCH }
    voice && [dsp.getbyte(voice << 4), dsp.getbyte((voice << 4) + ENVX)]
  end

  # An effect taking a voice a song's note was waiting for keeps its own fade.
  def test_a_shaped_effect_goes_on_fading_on_a_voice_it_took
    run = SNES::HeadlessRun.new
    loudness = []
    run.each_vblank do |_frame|
      voice = effect_voice(run)
      loudness << voice.first if voice
    end
    run.run(chords_game(work: 300, effect_envelope: { decay: 0.5, sustain: 0.1 }), frames: ASKED_ON_PASS + 40)

    assert_operator loudness.uniq.length, :>, 3, "its loudness: #{loudness.uniq}"
  end

  # The tune stopped on the pass that asks for the effect: the tune's voices are let go, and the
  # effect that starts after it is not let go with them.
  def test_a_tune_stopped_as_an_effect_starts_does_not_cut_the_effect
    run = SNES::HeadlessRun.new.tap { |player| player.run(chords_game(work: 300, stops_tune: true), frames: ASKED_ON_PASS + 12) }

    assert_equal [:tone], run.active_samples.uniq
    assert_operator effect_voice(run).last, :>, 0, "the voice sounding the effect"
  end
end
