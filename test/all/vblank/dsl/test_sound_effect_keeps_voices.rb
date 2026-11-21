# frozen_string_literal: true

require "test_helper"

# A sound effect that keeps its voices to its end. A silent note or a rest gives a voice back at once,
# which is right for a game written here. A cartridge's own sound engine can keep the voice until
# the effect itself ends, so a song note falling in that silence is lost, and `keeps_voices: true`
# on the effect's Score says so.
class TestSoundEffectKeepsVoices < Minitest::Test
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note

  SONG_PITCHES = [262, 330, 392, 523, 659].freeze # C4 E4 G4 C5 E5, one every ten frames
  SONG = Score.new(tempo: 150, length: 50, parts: [Part.new(notes: %i[C4 E4 G4 C5 E5].each_with_index.map do |key, n|
    Note.new(at: n * 10, key: key, length: 10)
  end)])

  # An effect loud for 6 frames, then silent, ending at frame 18. It starts with the song, whose
  # first note it takes, so the song's note at frame 10 falls in the silence.
  private def effect(silent, keeps_voices:)
    Score.new(tempo: 150, length: 18, plays_once: true, keeps_voices: keeps_voices,
              parts: [Part.new(notes: [Note.new(at: 0, key: :A5), silent])])
  end

  # What voice one played, as [frame, who, pitch].
  private def played(sound, frames: 45)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      music = songs :music, [SONG]
      list = sound_effects :sfx, { ding: sound }
      music.play 0
      list.play :ding
      game_loop { wait_vblank }
    end
    b.finalize_program
    player = game_player
    seen = []
    logged = 0
    player.each_vblank do |frame|
      player.audio.drop(logged).each { |entry| seen << [frame, entry[2], entry[3]] if entry.first == :voice && entry[1] == 1 }
      logged = player.audio.size
    end
    player.run(b.program, frames: frames)
    seen
  end

  private def song_pitches(seen) = seen.map(&:last).select { |pitch| SONG_PITCHES.include?(pitch) }

  def test_a_silent_note_gives_the_voice_back_by_default
    assert_includes song_pitches(played(effect(Note.new(at: 6, key: :A5, volume: 0), keeps_voices: false))), 330
  end

  def test_an_effect_that_keeps_its_voices_holds_through_a_silent_note
    assert_equal [392, 523, 659], song_pitches(played(effect(Note.new(at: 6, key: :A5, volume: 0), keeps_voices: true)))
  end

  def test_an_effect_that_keeps_its_voices_holds_through_a_rest
    assert_equal [392, 523, 659], song_pitches(played(effect(Note.new(at: 6, key: 0), keeps_voices: true)))
  end

  def test_the_voice_goes_quiet_when_the_effect_ends
    seen = played(effect(Note.new(at: 6, key: :A5, volume: 0), keeps_voices: true))

    assert seen.any? { |_, who, pitch| who == :"sfx.ding" && pitch.zero? }, "the effect's end lets the voice go"
  end

  def test_a_song_cannot_keep_voices
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval { songs :music, [Score.new(keeps_voices: true, parts: [Part.new(notes: [Note.new(at: 0, key: :A5)])])] }
    end

    assert_match(/keeps_voices/, error.message)
  end
end
