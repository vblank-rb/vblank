# frozen_string_literal: true

# A recorded note whose volume holds a fraction, on every console whose build mixes recordings: a
# volume of 15 x L / 512 plays the recording at L 512ths of its size, the loudness a port reads off
# its original's sound driver. Each console's folder has a test file that includes these, so they
# are written once and played on every run that plays games as one of those consoles:
#
#   test/console/gba/vblank/audio/test_recorded_fraction_volumes_on_the_advance.rb
#   test/console/snes/vblank/audio/test_recorded_fraction_volumes_on_the_super_nintendo.rb
#   test/console/ps1/vblank/audio/test_recorded_fraction_volumes_on_the_playstation.rb
#   test/console/genesis/vblank/audio/test_recorded_fraction_volumes_on_the_genesis.rb
#
# What each console's sound chip is set to for such a note is read in that lowering's own folder.
module RecordedFractionVolumeGames
  Score = VBlank::Audio::Score

  # A Score of one long note of a recorded instrument at +loudness+ 512ths.
  private def fraction_score(loudness)
    note = Score::Note.new(at: 0, key: :C4, volume: Rational(15 * loudness, 512))
    Score.new(tempo: 150, length: 96, parts: [Score::Part.new(plays: :tone, notes: [note])])
  end

  # A game that plays #fraction_score as a song, or as a sound effect on its second pass. A song's
  # game sets the music volume, so the interpreter logs each recorded note's loudness.
  private def fraction_game(loudness, as:, builder: VBlank::Builder.new)
    score = fraction_score(loudness)
    builder.instance_eval do
      enable_sound
      instrument :tone, pcm: [60, -60] * 16_000, rate: 32_000, note: :C4
      if as == :song
        music_volume 100
        songs(:music, [score]).play 0
        game_loop { wait_vblank }
      else
        effects = sound_effects(:sfx, { chime: score })
        passes = var :passes, 0
        game_loop do
          passes += 1
          effects.play 0 if passes == 2
          wait_vblank
        end
      end
    end
    builder.finalize_program
    builder.program
  end
end

module RecordedFractionVolumeTests
  include RecordedFractionVolumeGames

  def test_a_song_note_with_a_fraction_in_its_volume_plays_at_its_loudness
    played = game_player.run(fraction_game(444, as: :song), frames: 8).audio

    assert_includes played, [:loudness, [:mixer, 0], 444]
  end

  def test_a_sound_effect_note_with_a_fraction_in_its_volume_plays
    played = game_player.run(fraction_game(500, as: :effect), frames: 8).audio

    assert_includes played, [:note, :"sfx.chime", VBlank::Audio::Music::NOTE_FREQUENCIES[:C4]]
  end
end
