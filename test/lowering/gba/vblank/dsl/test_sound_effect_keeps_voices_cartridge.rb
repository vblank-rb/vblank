# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A sound effect that keeps its voices, on the Advance's own cartridge: how loud its first square
# voice is set, frame by frame, read in the emulator. What every run plays is in
# test/all/vblank/dsl/test_sound_effect_keeps_voices.rb.
class TestSoundEffectKeepsVoicesCartridge < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  VOICE = VBlank::Console::Hardware::REG_SOUND1CNT_H
  # One song note every ten frames, each at a volume of its own, so the voice says which it is on.
  SONG = Score.new(tempo: 150, length: 50, parts: [Part.new(notes: [8, 7, 6, 5, 4].each_with_index.map do |volume, n|
    Note.new(at: n * 10, key: :C4, length: 10, volume: volume)
  end)])

  private def game(keeps_voices)
    effect = Score.new(tempo: 150, length: 18, plays_once: true, keeps_voices: keeps_voices,
                       parts: [Part.new(notes: [Note.new(at: 0, key: :A5, volume: 15), Note.new(at: 6, key: :A5, volume: 0)])])
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      music = songs :music, [SONG]
      list = sound_effects :sfx, { ding: effect }
      music.play 0
      list.play :ding
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # The volumes the voice was set to, in turn.
  private def volumes(program, name)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "keeps.gba")
      assemble_rom(program, name: name).write(path)
      probe = VBlank::Diagnostics::Emulator.probe(path)
      seen = Array.new(50) do
        probe.step(1)
        (probe.read32(VOICE) & 0xFFFF) >> 12
      end
      probe.close
      seen.chunk_while { |a, b| a == b }.map(&:first).drop_while(&:zero?)
    end
  end

  def test_the_song_gets_its_voice_back_at_a_silent_note_by_default
    assert_equal [15, 0, 7, 6, 5, 4], volumes(game(false), "GIVEN").first(6)
  end

  def test_an_effect_that_keeps_its_voices_loses_the_song_note_in_its_silence
    assert_equal [15, 0, 6, 5, 4], volumes(game(true), "KEPT").first(5)
  end
end
