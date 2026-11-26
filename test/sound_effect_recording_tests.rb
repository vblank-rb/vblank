# frozen_string_literal: true

# Sound effects whose parts play a recording, on every console whose build mixes recordings for
# its tunes: the Advance's and the Super Nintendo's. An effect's recorded note sounds on a voice
# the effect owns, and shares the voices with the song and the game's own sounds by rank. Each
# console's folder has a test file that includes these:
#
#   test/console/gba/vblank/dsl/test_sound_effects_on_the_advance.rb
#   test/console/snes/vblank/dsl/test_sound_effects_on_the_super_nintendo.rb
#
# The games are kept apart (SoundEffectRecordingGames) for the Advance's cartridge too
# (test/lowering/gba/vblank/dsl/test_sound_effects_on_the_advance_cartridge.rb).
module SoundEffectRecordingGames
  include SharedConstants

  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # The recordings the console of the run sounds together, and whose each is when a song's
  # recorded parts fill them.
  VOICES = VBlank::Console.described(VBlank::Testing.console).recordings_at_once
  SONG_PARTS = Ractor.make_shareable(Array.new(VOICES) { |part| [:song, part] })

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame.
  private def every_ten_ticks(*keys, plays: nil, priority: 0, length: nil)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key, length: length) }
    Score.new(tempo: 150, priority: priority, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game with +effects+ as sound effects and, when given, +tune+ as the song it plays from its
  # first pass — or a list of them, the first played. The block runs each pass with the effects,
  # the pass number and the songs. Every game has a recording to play, :piano, four seconds long
  # at middle C, which the block can play as @piano.
  private def game(effects, tune: nil, &body)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      @piano = instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      music = songs :music, Array(tune) if tune
      sfx = sound_effects :sfx, effects
      pass = 0
      game_loop do
        pass += 1
        music&.play 0
        instance_exec(sfx, pass, music, &body)
      end
    end
    b.finalize_program
    b.program
  end

  # What sounded on which frame, from the run: [who, frequency] for each note, where a frequency
  # of 0 is a voice going quiet.
  private def notes_by_frame(program, frames)
    i = game_player
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).select { |entry| entry[0] == :note }.map { |entry| entry.drop(1) }
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
  end

  # A song whose +parts+ recorded parts each strike a note at each tick of +at+, at +priority+ —
  # held until the next unless it has a +length+, and shaped by +envelope+ when given.
  private def chord(parts, priority: 0, at: [0], length: nil, envelope: nil)
    notes = at.map { |tick| Note.new(at: tick, key: :C4, length: length) }
    Score.new(tempo: 150, priority: priority, length: 400,
              parts: Array.new(parts) { Part.new(plays: :piano, envelope: envelope, notes: notes) })
  end

  # One recorded note ranked at +priority+, asked for on pass 10.
  private def recorded_hit(priority, parts: 1)
    Score.new(tempo: 150, priority: priority, length: 30,
              parts: Array.new(parts) { Part.new(plays: :piano, notes: [Note.new(at: 0, key: :C5)]) })
  end

  # An effect that plays a recording, two notes ten ticks apart, asked for on pass 3.
  private def recorded_effect_asked_for_once
    game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| sfx.play 0 if pass == 3 }
  end

  # Recorded effects in a group: cut off, not played for a lower one, on a tie, and asked for
  # again — whose each mixer voice is, the same on every backend.
  private def long_recorded(key, priority)
    Score.new(tempo: 150, priority: priority, group: :voice,
              parts: [Part.new(plays: :piano, notes: [Note.new(at: 5, key: key, length: 60)])])
  end

  private def recorded_pair(first:, second:, asks: [0, 1])
    game([long_recorded(:C4, first), long_recorded(:E4, second)]) do |sfx, pass|
      sfx.play asks.first if pass == 3
      sfx.play asks.last if pass == 14
    end
  end

  # Each pair of recorded effects, and whose each mixer voice is the given frames in.
  private def recorded_pairs_and_owners
    cry_alone = [[:"sfx.0", 0]]
    hurt_alone = [[:"sfx.1", 0]]
    {
      recorded_pair(first: 64, second: 72) => { 10 => cry_alone, 22 => hurt_alone },
      recorded_pair(first: 72, second: 64) => { 10 => cry_alone, 22 => cry_alone },
      recorded_pair(first: 64, second: 64) => { 10 => cry_alone, 22 => hurt_alone },
      recorded_pair(first: 64, second: 72, asks: [0, 0]) => { 10 => cry_alone, 17 => [], 22 => cry_alone },
    }
  end

  # An effect filling every voice from pass 3, over a recorded song with a note every twenty ticks.
  private def effect_filling_the_mixer
    tune = Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C4), Note.new(at: 20, key: :E4), Note.new(at: 40, key: :G4),
    ])])
    game([recorded_hit(68, parts: VOICES)], tune: tune) { |sfx, pass| sfx.play 0 if pass == 3 }
  end

  # An effect of two shaped notes two frames apart, asked for on pass 3; with +cuts+ it cuts its own
  # notes (`cuts_own_notes: true`).
  private def two_quick_shaped_notes(cuts:)
    score = Score.new(tempo: 150, cuts_own_notes: cuts, parts: [Part.new(plays: :piano, envelope: { release: 0.5 }, notes: [
      Note.new(at: 0, key: :C4, length: 2), Note.new(at: 2, key: :E4, length: 2),
    ])])
    game([score]) { |sfx, pass| sfx.play 0 if pass == 3 }
  end

  # The effect's voice through a restart, its own restart, its end, and a shaped end: each game,
  # whose each mixer voice is, and how many frames in.
  private def effect_voices_kept_and_let_go
    two_notes = every_ten_ticks(:C4, :E4, plays: :piano)
    restarted = game([two_notes]) { |sfx, pass| sfx.play 0 if pass == 3 || pass == 8 }
    song_restarts = game([recorded_hit(68)], tune: chord(1)) do |sfx, pass|
      sfx.play 0 if pass == 10
      stop_music if pass == 15
    end
    ended = game([two_notes]) { |sfx, pass| sfx.play 0 if pass == 3 }
    shaped = game([Score.new(tempo: 150, parts: [Part.new(plays: :piano, envelope: { release: 0.25 },
                                                          notes: [Note.new(at: 0, key: :C4, length: 20)])])]) do |sfx, pass|
      sfx.play 0 if pass == 3
    end

    sounding = [[:"sfx.0", 0]]
    { restarted => sounding, song_restarts => [[:song, 0], [:"sfx.0", 0]], ended => [], shaped => sounding }
      .zip([12, 18, 40, 26]).map { |(program, owners), frames| [program, owners, frames] }
  end
end

# A score played once, as a sound effect, whose part plays a recording: its notes on voices of
# the mixer the effect owns, shared with the song and the game's own sounds by rank.
module SoundEffectRecordingTests
  include SoundEffectRecordingGames

  # The voices sounding after +frames+: whose each one is, and the recording it plays.
  private def voices_after(program, frames)
    i = game_player.run(program, frames: frames)
    i.sound_owners.zip(i.active_samples)
  end

  # A part that plays a recording sounds each note on a voice of the mixer, which is the effect's.
  def test_an_effect_plays_a_recording_on_a_voice_of_its_own
    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(recorded_effect_asked_for_once, 8)
  end

  # Asked for again, its first note takes over the voice its last note was on, rather than a
  # second one.
  def test_an_effect_asked_for_again_keeps_its_one_voice
    program = game([every_ten_ticks(:C4, :E4, plays: :piano)]) { |sfx, pass| sfx.play 0 if pass == 3 || pass == 8 }

    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(program, 12)
  end

  # At its end the effect lets its voice go, although the recording has further to run...
  def test_an_effect_lets_its_voice_go_at_its_end
    program = recorded_effect_asked_for_once

    assert_equal [[:"sfx.0", NOTES[:E4]]], notes_by_frame(program, 40)[14]
    assert_equal [[:"sfx.0", 0]], notes_by_frame(program, 40)[38]
    assert_empty voices_after(program, 40)
  end

  # ...and a note with a shape falls away there instead of stopping.
  def test_a_shaped_effect_note_falls_away_at_its_end
    shaped = Score.new(tempo: 150, parts: [Part.new(plays: :piano, envelope: { release: 0.25 },
                                                    notes: [Note.new(at: 0, key: :C4, length: 20)])])
    program = game([shaped]) { |sfx, pass| sfx.play 0 if pass == 3 }

    assert_equal [[[:"sfx.0", 0], :piano]], voices_after(program, 26), "still falling away just after its end"
    assert_empty voices_after(program, 60), "and gone once it has"
  end

  # A note plays the recording at its own pitch, reading it faster for a higher note: two octaves
  # up, the four seconds last one.
  def test_an_effect_note_plays_its_recording_at_the_notes_pitch
    long_note = ->(key) { Score.new(tempo: 150, length: 200, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: key)])]) }
    at = ->(key) { game([long_note.call(key)]) { |sfx, pass| sfx.play 0 if pass == 3 } }

    assert_equal 1, voices_after(at.call(:C4), 80).size
    assert_empty voices_after(at.call(:C6), 80)
  end

  # --- sharing the mixer ---

  # Every voice holds the song, and the effect outranks it: the effect's note takes a voice from
  # the song — the first of them, since they all rank the same.
  def test_an_effect_note_takes_a_voice_from_a_song_it_outranks
    program = game([recorded_hit(68)], tune: chord(VOICES)) { |sfx, pass| sfx.play 0 if pass == 10 }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), game_player.run(program, frames: 20).sound_owners
  end

  # The song outranks the effect: the effect's note is not played, and nothing of the song's is
  # touched.
  def test_an_effect_note_below_the_song_with_every_voice_busy_is_not_played
    program = game([recorded_hit(68)], tune: chord(VOICES, priority: 80)) { |sfx, pass| sfx.play 0 if pass == 10 }
    i = game_player.run(program, frames: 20)

    assert_equal SONG_PARTS, i.sound_owners
    assert_includes i.audio, [:sound_effect, :"sfx.0"]
    refute_includes i.audio, [:note, :"sfx.0", NOTES[:C5]]
    assert_equal 1, i.sound_drops.dropped, "the profile counts the note that did not play"
  end

  # The other way round: an effect fills every voice, and the song's note under it is not played.
  # The song carries on in time, and is heard again from its next note once the effect is over.
  def test_a_song_note_below_an_effect_filling_every_voice_is_heard_from_its_next_note
    heard = notes_by_frame(effect_filling_the_mixer, 50)

    assert_equal [[:"music.0", NOTES[:C4]]], heard[2]
    refute heard.key?(22), "the song's second note is not played"
    assert_equal [[:"music.0", NOTES[:G4]]], heard[42]
  end

  # The game's own sounds rank below every song and effect, so they give way first.
  def test_an_effect_note_takes_the_games_own_sound_before_the_songs
    program = game([recorded_hit(68)], tune: chord(VOICES - 1)) do |sfx, pass|
      @piano.play(:G4) if pass == 1
      sfx.play 0 if pass == 10
    end
    i = game_player.run(program, frames: 20)

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.take(VOICES - 1), i.sound_owners
  end

  # Every voice holds a song note that has ended and is fading away: the effect's note takes the
  # quietest of those, whoever's it is, rather than one ranked below it.
  def test_an_effect_note_takes_a_fading_note_first
    fading = chord(VOICES, length: 8, envelope: { release: 1.0 })
    program = game([recorded_hit(68)], tune: fading) { |sfx, pass| sfx.play 0 if pass == 12 }
    i = game_player.run(program, frames: 16)

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), i.sound_owners
    assert_equal 0, i.sound_drops.dropped
  end

  # A song part that loses its voice to an effect is heard again from its next note.
  def test_a_song_part_that_loses_its_voice_has_one_again_at_its_next_note
    program = game([recorded_hit(68)], tune: chord(VOICES, at: [0, 60])) { |sfx, pass| sfx.play 0 if pass == 10 }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), game_player.run(program, frames: 30).sound_owners
    assert_equal SONG_PARTS, game_player.run(program, frames: 70).sound_owners
  end

  # A note at volume 0 sounds nothing, so on the mixer too it takes no voice and lets go of the
  # one its part had — the same as a rest.
  def test_a_silent_recorded_note_takes_no_voice
    quiet = Score.new(tempo: 150, priority: 68, length: 60, parts: [Part.new(plays: :piano, notes: [
      Note.new(at: 0, key: :C5), Note.new(at: 10, key: :D5, volume: 0),
    ])])
    program = game([quiet], tune: chord(VOICES)) { |sfx, pass| sfx.play 0 if pass == 10 }

    assert_equal [[:"sfx.0", 0]] + SONG_PARTS.drop(1), game_player.run(program, frames: 15).sound_owners
    assert_equal SONG_PARTS.drop(1), game_player.run(program, frames: 25).sound_owners
  end

  # The song starting over lets go of its own voices and not the effect's.
  def test_starting_the_song_over_leaves_an_effects_recorded_note_alone
    program = game([recorded_hit(68)], tune: chord(1)) do |sfx, pass|
      sfx.play 0 if pass == 10
      stop_music if pass == 15
    end

    assert_includes game_player.run(program, frames: 18).sound_owners, [:"sfx.0", 0]
  end

  # Whose each mixer voice is for an effect that plays a recording: the effect's own.
  def test_an_effects_recording_sounds_on_a_voice_the_effect_owns
    assert_equal [[:"sfx.0", 0]], game_player.run(recorded_effect_asked_for_once, frames: 8).sound_owners
  end

  # Recorded effects in a group: whose each mixer voice is, frame by frame.
  def test_a_group_of_recorded_effects_decides_whose_each_voice_is
    recorded_pairs_and_owners.each do |program, moments|
      moments.each do |frames, owners|
        assert_equal owners, game_player.run(program, frames: frames).sound_owners, "#{frames} frames in"
      end
    end
  end

  # An effect filling every voice: the song's note under it is not played, and its next one is.
  def test_the_songs_next_note_has_a_voice_once_an_effect_filling_the_mixer_ends
    assert_equal [[:song, 0]], game_player.run(effect_filling_the_mixer, frames: 45).sound_owners
  end

  # Two shaped notes two frames apart. Each falls away on its own voice while the next takes another,
  # so the two overlap; with `cuts_own_notes: true` the second takes the first's voice, as a sound
  # driver keys each note of a part on one voice.
  def test_an_effect_that_cuts_its_own_notes_plays_them_on_one_voice
    assert_equal [[:"sfx.0", 0]] * 2, game_player.run(two_quick_shaped_notes(cuts: false), frames: 9).sound_owners
    assert_equal [[:"sfx.0", 0]], game_player.run(two_quick_shaped_notes(cuts: true), frames: 9).sound_owners
  end

  # The effect's voice through a restart, its own restart, its end, and a shaped end.
  def test_an_effects_voice_is_kept_and_let_go_through_restarts_and_ends
    effect_voices_kept_and_let_go.each do |program, owners, frames|
      assert_equal owners, game_player.run(program, frames: frames).sound_owners, "#{frames} frames in"
    end
  end
end
