# frozen_string_literal: true

require "test_helper"

# A song's notes that fade out or swell in, on the console's square and noise voices.
#
# A square or noise voice can change its own loudness while a note holds: it starts at the note's
# volume and steps it down (or up) by one every so many 64ths of a second, with nothing from the
# game. A drum hit and a beep always did that. A song's square-wave notes did not: each one held
# at its volume until the next, like an organ, and most music written for these voices has notes
# that fade like a plucked string or swell like a bowed one.
#
# What the Advance's cartridge tells its sound hardware is in
# test/lowering/gba/vblank/audio/test_song_note_fades_cartridge.rb.

# The songs both files play.
module SongNoteFadesGames
  # One song, written by the block, played until its notes have all started.
  private def song_game(&parts)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        tempo 150 # a quarter is 24 frames
        instance_eval(&parts)
      end
      play_song :tune
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  # Two square parts, one fading and one swelling in from silence.
  private def fade_and_swell_game
    song_game do
      voice :lead do |v|
        v.decay :slow
        v.note :C4, :whole
      end
      voice :pad do |v|
        v.volume 0
        v.swell :fast
        v.note :G4, :whole
      end
    end
  end
end

class TestSongNoteFades < Minitest::Test
  include SongNoteFadesGames

  NoteFade = VBlank::Audio::NoteFade

  # What the song set its voices to, in the order it set them: [voice, pitch, volume, fade]. Two
  # quarters are 48 frames, so 40 is every note of a two-note part once, before it comes round.
  private def voices_set(program, frames: 40)
    game_player.run(program, frames: frames).audio
               .select { |entry| entry.first == :voice }
               .map { |_, voice, _song, pitch, volume, fade| [voice, pitch, volume, fade] }
  end

  def test_a_square_part_that_decays_fades_every_note_it_plays
    c4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:C4]
    e4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:E4]
    played = voices_set(song_game do
      voice :lead do |v|
        v.decay :slow
        v.note :C4, :quarter
        v.note :E4, :quarter
      end
    end)

    assert_equal [[1, c4, 12, NoteFade.fading(5)], [1, e4, 12, NoteFade.fading(5)]], played
  end

  # A note can say its own, in place of its part's: a pluck in a bowed line, or one note that
  # starts quieter. And a note that says nothing takes its part's.
  def test_a_notes_own_fade_and_volume_come_before_its_parts
    c4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:C4]
    e4 = VBlank::Audio::Music::NOTE_FREQUENCIES[:E4]
    played = voices_set(song_game do
      voice :lead do |v|
        v.swell :medium
        v.note :C4, :quarter, decay: 2, volume: 9
        v.note :E4, :quarter
      end
    end)

    assert_equal [[1, c4, 9, NoteFade.fading(2)], [1, e4, 12, NoteFade.swelling(3)]], played
  end

  # A drum that says nothing of a note's fade rings out as its part says, and the log says what it
  # always did; a hit that says its own is logged with it.
  def test_a_drum_hit_says_its_fade_only_when_the_note_does
    c2 = VBlank::Audio::Music::NOTE_FREQUENCIES[:C2]
    played = voices_set(song_game do
      voice :drums, plays: :noise do |v|
        v.decay :slow
        v.note :C2, :quarter
        v.note :C2, :quarter, swell: 1
      end
    end)

    assert_equal [[4, c2, 12, nil], [4, c2, 12, NoteFade.swelling(1)]], played
  end

  # A score says it the same way, for a game that converts another game's music into one: a part's
  # `decay:` or `swell:`, and a note's own, as a speed or as the step itself.
  def test_a_score_says_how_its_notes_fade
    score = VBlank::Audio::Score
    # A beat each, 24 ticks, at 150 beats a minute: 24 frames.
    lead = score::Part.new(swell: 4, notes: [score::Note.new(at: 0, key: 60, length: 24),
                                             score::Note.new(at: 24, key: 64, length: 24, decay: 7, volume: 15)])
    tune = score.new(parts: [lead], tempo: 150)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      music = songs :music, [tune]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program

    sounding = voices_set(b.program).reject { |_, pitch| pitch.zero? }
    assert_equal [[12, NoteFade.swelling(4)], [15, NoteFade.fading(7)]], sounding.map { |_, _, volume, fade| [volume, fade] }
  end

  # The music volume reaches a held note by striking it again, which would start a fading note's
  # fade over — and during a fade of the music it moves every frame, so a plucked note would never
  # die away. So a note that fades by itself is left to fade, the way a drum hit is, and only the
  # note that holds takes the new volume while it sounds.
  def test_a_new_music_volume_strikes_only_the_note_that_holds
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        voice(:lead) { |v| v.decay :slow; v.note :C4, :whole }
        voice(:bass) { |v| v.note :C3, :whole }
      end
      play_song :tune
      count = 0
      game_loop do
        count += 1
        music_volume 50 if count == 10
        wait_vblank
      end
    end
    b.finalize_program

    log = game_player.run(b.program, frames: 20).audio
    after = log.drop(log.index([:loudness, 2, 12]) + 1)

    assert_equal [[:loudness, 2, 6]], after.select { |entry| entry.first == :loudness },
                 "the bass is struck again at half; the fading lead is left to fade"
  end

  # A pad swelling in from nothing, a step every 64th of a second, under the music volume the
  # block sets.
  private def swelling_pad_game(&volume)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        voice(:pad) { |v| v.volume 0; v.swell :fast; v.note :G4, :whole }
      end
      play_song :tune
      count = 0
      game_loop do
        count += 1
        instance_exec(count, &volume)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  private def loudness_of_pad(program, frames:)
    game_player.run(program, frames: frames).audio.select { |entry| entry.first == :loudness && entry[1] == 1 }
  end

  # A swelling note stops at the music volume. The voice counts its loudness up by itself, as far as
  # full, whatever the music volume is. So the player counts with it, and when the note reaches
  # the loudest the music volume lets a note be, strikes it again there, holding.
  def test_a_swelling_note_stops_at_the_music_volume
    entries = loudness_of_pad(swelling_pad_game { |count| music_volume 50 if count == 1 }, frames: 40)

    assert_equal [:loudness, 1, 7], entries.last, "at half, the pad holds at 7 of 15"
    assert_equal 1, entries.count { |entry| entry[2] == 7 }, "and is struck there once"
  end

  # ...AND fades with the music. While the music fades out, the pad held at the music volume is
  # struck lower each time the volume drops below it, down to nothing.
  def test_a_swelling_note_fades_out_with_the_music
    entries = loudness_of_pad(swelling_pad_game { |count| fade_music_out frames: 20 if count == 30 }, frames: 80)
    struck_down = entries.drop(1).map { |entry| entry[2] } # past the note's own start, at nothing

    assert_operator struck_down.first.to_i, :>, 7, "the pad had swelled up before the fade"
    assert_equal struck_down.sort.reverse, struck_down, "and is only ever struck lower as the music fades"
    assert_equal [:loudness, 1, 0], entries.last, "the pad is silent at the end of the fade"
  end

  # ...AND SWELLS ON when the music volume comes back up, from where it was held.
  def test_a_held_swell_swells_on_when_the_music_comes_back
    entries = loudness_of_pad(swelling_pad_game do |count|
      music_volume 50 if count == 1
      music_volume 100 if count == 40
    end, frames: 60)

    assert_equal [:loudness, 1, 7, NoteFade.swelling(1)], entries.last, "struck at 7 again, swelling"
  end

  # A drum hit swelling in from nothing on the noise voice, under the music volume the block sets.
  private def swelling_drum_game(&volume)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) do
        voice(:drums, plays: :noise) { |v| v.volume 0; v.note :C6, :whole, swell: :fast }
      end
      play_song :tune
      count = 0
      game_loop do
        count += 1
        instance_exec(count, &volume)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  private def loudness_of_drum(program, frames:)
    game_player.run(program, frames: frames).audio.select { |entry| entry.first == :loudness && entry[1] == 4 }
  end

  # A drum hit is held the same way, on the noise voice.
  def test_a_swelling_drum_hit_stops_at_the_music_volume
    entries = loudness_of_drum(swelling_drum_game { |count| music_volume 50 if count == 1 }, frames: 40)

    assert_equal [:loudness, 4, 7], entries.last, "at half, the hit holds at 7 of 15"
  end

  def test_a_swelling_drum_hit_fades_out_with_the_music
    entries = loudness_of_drum(swelling_drum_game { |count| fade_music_out frames: 20 if count == 30 }, frames: 80)

    assert_equal [:loudness, 4, 0], entries.last, "the hit is silent at the end of the fade"
  end

  def test_a_held_drum_hit_swells_on_when_the_music_comes_back
    entries = loudness_of_drum(swelling_drum_game do |count|
      music_volume 50 if count == 1
      music_volume 100 if count == 40
    end, frames: 60)

    assert_equal [:loudness, 4, 7, NoteFade.swelling(1)], entries.last, "struck at 7 again, swelling"
  end

  # ...BUT a swelling note that slides is left alone, as the music volume leaves every sliding note:
  # striking it again would start its slide over.
  def test_a_swelling_note_that_slides_is_left_alone
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      enable_sound
      song(:tune) { voice(:pad) { |v| v.volume 0; v.swell :fast; v.note :G4, :whole, slide_down: :slow } }
      play_song :tune
      music_volume 50
      game_loop { wait_vblank }
    end
    b.finalize_program

    assert_equal 1, loudness_of_pad(b.program, frames: 40).size, "struck once, as it starts"
  end

  # --- what a fade cannot be said of ---

  def test_a_part_on_the_wave_voice_cannot_fade_its_notes
    error = assert_raises(ArgumentError) do
      song_game { voice(:pad, plays: :wave) { |v| v.decay :slow; v.note :C3, :whole } }
    end

    assert_match(/only the square and noise voices can fade a note/i, error.message)
    assert_match(/:pad/, error.message)
  end

  def test_a_note_that_both_fades_and_swells_is_refused
    error = assert_raises(ArgumentError) do
      song_game { voice(:lead) { |v| v.note :C4, :quarter, decay: :fast, swell: :fast } }
    end

    assert_match(/both `decay:` and `swell:`/, error.message)
  end

  def test_a_speed_that_is_not_one_says_what_it_can_be
    error = assert_raises(ArgumentError) { song_game { voice(:lead) { |v| v.swell 9 } } }

    assert_match(/:fast, :medium, :slow or :none/, error.message)
    assert_match(/0 to 7/, error.message)
  end
end
