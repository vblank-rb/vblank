# frozen_string_literal: true

require "test_helper"

require "stringio"

# The songs and the game these tests hand them to, kept once for this file and for the tests of
# the same songs on the Advance's cartridge (test/lowering/gba/vblank/audio/test_scores_cartridge.rb).
module ScoresGames
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame — so a note's tick is the
  # frame it sounds on, counted from the frame the song starts.
  private def notes_every_ten_ticks(*keys, plays: nil, tempo: 150)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key) }
    Score.new(tempo: tempo, parts: [Part.new(plays: plays, notes: notes)])
  end

  # The recorded instruments a song here may name, each by its samples.
  INSTRUMENT_SAMPLES = Ractor.make_shareable({ piano: [60, -60] * 4000, harp: [40, -40] * 4000 })

  # The instruments of INSTRUMENT_SAMPLES that +scores+ name, on a part or on a note.
  private def instruments_named(scores)
    named = scores.flat_map { |score| score.parts.flat_map { |part| [part.plays, *part.notes.map(&:instrument)] } }
    INSTRUMENT_SAMPLES.keys & named
  end

  # A game that hands over +scores+, names one each pass with the block, and otherwise does
  # nothing. The block is handed the song list and how many passes have run.
  #
  # It declares only the instruments its songs name. A console that plays a song on its own voices
  # alone refuses a game that writes `instrument` at all, so a song of square, wave and noise
  # parts must bring none in to play there.
  private def game(scores, &body)
    recorded = instruments_named(scores)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      recorded.each { |name| instrument name, pcm: INSTRUMENT_SAMPLES.fetch(name), rate: 8000, note: :C4 }
      music = songs :music, scores
      pass = var :pass, 0
      game_loop do
        pass += 1
        instance_exec(music, pass, &body)
      end
    end
    b.finalize_program
    b.program
  end

  # One note held for the whole of a song twenty frames long.
  private def held_note(plays: nil, **options)
    Score.new(tempo: 150, length: 20, **options, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C5)])])
  end

  # A MIDI key reaches no further than 12,543 Hz, and the noise voice steps as fast as 524,288
  # times a second, so a drum decoded off another cartridge says its rate with `hz:` instead.
  private def drums_at(*rates, plays: :noise)
    notes = rates.each_with_index.map { |rate, n| Note.new(at: n * 4, hz: rate) }
    Score.new(tempo: 150, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A drum that names the noise voice's own setting: its divider and how many times it is halved.
  # [1, 1] and [0, 2] step at the same 131,072 a second, and another game's engine says one of them.
  private def drum_with_clock(clock, plays: :noise, **part)
    Score.new(tempo: 150, parts: [Part.new(plays: plays, **part, notes: [Note.new(at: 0, noise_clock: clock)])])
  end
end

# Music handed over as data. A game whose music already exists as numbers — decoded out of
# another cartridge, read from a file — hands the framework Scores, and picks one to play by a
# number it works out as it runs: `music = songs :music, scores` then `music.play track`.
# Nothing about the tune is written in the program.
#
# What the Advance's cartridge plays — its voices, its speaker, its noise register, and the
# bytes it is built to — is in test/lowering/gba/vblank/audio/test_scores_cartridge.rb.
class TestScores < Minitest::Test
  include ScoresGames

  # --- low notes ---

  def test_saying_it_with_anything_but_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: 60)])], low_notes_intended: :yes).to_song
    end
    assert_match(/must be true or false/, error.message)
  end

  # --- a song that plays once ---

  # What the sound log took, by frame: the notes on each frame that had any, and the frames on
  # which the music stopped.
  Heard = Data.define(:notes, :stops)

  # Two notes ten frames apart in a song twenty frames long, which says it plays once.
  private def two_notes_once(**options)
    Score.new(tempo: 150, length: 20, plays_once: true, **options,
              parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)])])
  end

  # #two_notes_once named on the first pass and taken up as frame 2 starts: its twenty frames are 2
  # to 21, and its part goes quiet on frame 22, the frame after its last — not on frame 21, which
  # still sounds the note.
  TWO_NOTES_ONCE_HEARD = Heard.new(notes: { 2 => [NOTES[:C4]], 12 => [NOTES[:E4]] }, stops: [22])

  private def heard_by_frame(program, frames)
    player = game_player
    notes = {}
    stops = []
    logged = 0
    player.each_vblank do |frame|
      fresh = player.audio.drop(logged)
      logged = player.audio.size
      played = fresh.select { |entry| entry[0] == :note }.map(&:last)
      notes[frame] = played unless played.empty?
      stops << frame if fresh.include?([:stop_music])
    end
    player.run(program, frames: frames)
    Heard.new(notes: notes, stops: stops)
  end

  # Named every pass after its end, it is not heard again.
  def test_a_song_that_plays_once_named_every_pass_goes_quiet_the_frame_after_its_last
    program = game([two_notes_once]) { |music, _| music.play 0 }

    assert_equal TWO_NOTES_ONCE_HEARD, heard_by_frame(program, 40)
  end

  # The same when the game names it once and never again.
  def test_a_song_that_plays_once_named_once_goes_quiet_the_frame_after_its_last
    program = game([two_notes_once]) { |music, pass| music.play 0 if pass == 1 }

    assert_equal TWO_NOTES_ONCE_HEARD, heard_by_frame(program, 40)
  end

  # Once it has ended it stays ended for as long as the game names it, even in a pass that names
  # another song first and then this one again: the song named last is the one wanted, and that is
  # the ended one.
  def test_a_song_that_plays_once_stays_ended_when_another_is_named_before_it_in_a_pass
    program = game([two_notes_once, notes_every_ten_ticks(:G4)]) do |music, pass|
      music.play 1 if pass == 40
      music.play 0
    end

    assert_equal TWO_NOTES_ONCE_HEARD, heard_by_frame(program, 60)
  end

  # Named to start where it is named (`this_frame: true`), its first frame is the first pass's own,
  # read with that pass's sound at frame 2: so its twenty frames are 1 to 20, and it goes quiet on
  # frame 21.
  def test_a_song_that_plays_once_named_for_this_frame_goes_quiet_the_frame_after_its_last
    program = game([two_notes_once]) { |music, _| music.play 0, this_frame: true }

    assert_equal Heard.new(notes: { 2 => [NOTES[:C4]], 11 => [NOTES[:E4]] }, stops: [21]), heard_by_frame(program, 40)
  end

  # The same in a game that has a sound effect too, whose player takes the frame in turns with the
  # song's: the effect sounds once, on pass 4, before the song ends.
  def test_a_song_that_plays_once_beside_a_sound_effect_goes_quiet_the_frame_after_its_last
    song = two_notes_once
    effect = notes_every_ten_ticks(:G4)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      music = songs :music, [song]
      sfx = sound_effects :sfx, { ping: effect }
      pass = var :pass, 0
      game_loop do
        pass += 1
        music.play 0
        sfx.play :ping if pass == 4
      end
    end
    b.finalize_program

    assert_equal TWO_NOTES_ONCE_HEARD.stops, heard_by_frame(b.program, 40).stops
  end

  # Which notes sounded on which frame.
  private def notes_by_frame(program, frames)
    i = game_player
    heard = {}
    logged = 0
    i.each_vblank do |frame|
      fresh = i.audio.drop(logged).select { |entry| entry[0] == :note }.map(&:last)
      logged = i.audio.size
      heard[frame] = fresh unless fresh.empty?
    end
    i.run(program, frames: frames)
    heard
  end

  # A held note in a song that plays once, with the music volume halved on pass 8 and put back
  # on pass 40, after the song has ended.
  private def volume_moved_after_a_song_ended
    game([held_note(plays_once: true)]) do |music, pass|
      music.play 0
      music_volume 50 if pass == 8
      music_volume 100 if pass == 40
    end
  end

  # It ends where its length says and is not heard again, though the game goes on naming it
  # every pass: naming the song already named changes nothing, whether or not it has ended.
  def test_a_song_that_plays_once_does_not_come_round
    program = game([two_notes_once]) { |music, _| music.play 0 }

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]] }, notes_by_frame(program, 70))
  end

  # A song that has ended is started the way any song is started over: stop the music and name
  # it, in the same pass or a later one.
  def test_a_song_that_ended_starts_over_after_a_stop
    program = game([two_notes_once]) do |music, pass|
      stop_music if pass == 40
      music.play 0
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 41 => [NOTES[:C4]], 51 => [NOTES[:E4]] },
                 notes_by_frame(program, 70), "stopped and named on pass 40, it plays once more and ends again")
  end

  # The stop and the naming can be passes apart.
  def test_a_song_that_ended_starts_over_when_named_some_passes_after_a_stop
    program = game([two_notes_once]) do |music, pass|
      music.play 0 if pass < 40
      stop_music if pass == 40
      music.play 0 if pass >= 45
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 46 => [NOTES[:C4]], 56 => [NOTES[:E4]] },
                 notes_by_frame(program, 70))
  end

  # ...or name another song first.
  def test_a_song_that_ended_starts_over_after_another_song
    program = game([two_notes_once, notes_every_ten_ticks(:G4)]) do |music, pass|
      track = var :track, 0
      track = 1 if pass == 40
      track = 0 if pass == 45
      music.play track
    end

    assert_equal({ 2 => [NOTES[:C4]], 12 => [NOTES[:E4]], 41 => [NOTES[:G4]], 46 => [NOTES[:C4]], 56 => [NOTES[:E4]] },
                 notes_by_frame(program, 70))
  end

  # The fades reach it as they reach any song: faded out and back in before it ends, its note
  # steps through the same volumes as the same song left to come round, down to nothing and
  # back to the written 12.
  def test_the_music_fades_reach_a_song_that_plays_once
    volumes = lambda do |score|
      program = game([score]) do |music, pass|
        music.play 0
        fade_music_out frames: 4 if pass == 4
        fade_music_in frames: 4 if pass == 12
      end
      game_player.run(program, frames: 20).audio.select { |entry| entry[0] == :loudness }.map(&:last)
    end
    once = volumes.call(held_note(plays_once: true))

    assert_equal volumes.call(held_note), once
    assert_includes once, 0
    assert_equal [12, 12], [once.first, once.last]
  end

  # The music volume reaches it like any song while it plays: halved on pass 8, the held note
  # is set again at half. Moved after the song has ended, it sets nothing, since nothing is held.
  def test_the_music_volume_reaches_a_song_that_plays_once_until_it_ends
    set = game_player.run(volume_moved_after_a_song_ended, frames: 60)
                     .audio.select { |entry| entry[0] == :loudness }.map { |entry| entry.drop(1) }
    assert_equal [[1, 12], [1, 6]], set, "the first square voice, at the written 12 and then at half"
  end

  # --- a note's length, instrument and loudness ---

  def test_a_volume_with_a_fraction_on_a_console_voice_is_a_friendly_error
    square = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4, volume: 7.5)])])
    assert_match(/whole number/, build_error { songs :music, [square] })
  end

  # --- what cannot be had, said plainly ---

  private def build_error(&program)
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        instance_exec(&program)
      end
    end
    err.message
  end

  def test_something_that_is_not_a_score_is_a_friendly_error
    assert_match(/Score/, build_error { songs :music, [:title_theme] })
  end

  def test_a_note_before_the_start_is_a_friendly_error
    bad = Score.new(parts: [Part.new(notes: [Note.new(at: -4, key: :C4)])])
    assert_match(/tick/, build_error { songs :music, [bad] })
  end

  def test_a_rate_on_a_part_that_is_not_the_noise_voice_is_a_friendly_error
    pad = drums_at(440, plays: :wave)
    message = build_error { songs :music, [pad] }

    assert_match(/only a part on the noise voice/i, message)
    assert_match(/key:/, message, "says what the part gives instead")
  end

  def test_a_note_with_both_a_key_and_a_rate_is_a_friendly_error
    both = Score.new(parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: 60, hz: 131_072)])])

    assert_match(/both/, build_error { songs :music, [both] })
  end

  def test_a_rate_the_noise_voice_cannot_make_is_a_friendly_error
    [0, -5, 600_000, "fast"].each do |rate|
      drums = drums_at(rate)
      assert_match(/524,288/, build_error { songs :music, [drums] }, "hz: #{rate.inspect}")
    end
  end

  # A drum's own setting steps at the rate the setting makes, on every backend.
  def test_a_drum_steps_at_the_rate_its_noise_setting_makes
    played = game_player.run(game([drum_with_clock([1, 1])]) { |music, _| music.play 0 }, frames: 6).audio
    pitches = played.filter_map { |kind, voice, _who, pitch| pitch if kind == :voice && voice == 4 && pitch.positive? }

    assert_equal [131_072], pitches.map(&:round).uniq
  end

  def test_a_noise_setting_off_the_noise_voice_is_a_friendly_error
    pad = drum_with_clock([1, 1], plays: :wave)

    assert_match(/only a part on the noise voice/i, build_error { songs :music, [pad] })
  end

  def test_a_noise_setting_the_voice_does_not_have_is_a_friendly_error
    [[8, 1], [1, 14], [1], "fast"].each do |clock|
      drums = drum_with_clock(clock)
      assert_match(/0 to 7.*0 to 13/m, build_error { songs :music, [drums] }, clock.inspect)
    end
  end

  def test_a_noise_setting_in_a_transposed_part_is_a_friendly_error
    drums = drum_with_clock([1, 1], transpose: 12)

    assert_match(/transpose/, build_error { songs :music, [drums] })
  end

  def test_a_written_number_past_the_last_song_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    message = build_error { songs(:music, [song, song]).play 5 }
    assert_match(/2 songs/, message)
  end

  def test_a_song_that_plays_once_and_loops_is_a_friendly_error
    both = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 48, key: :E4)])],
                     plays_once: true, loop_from: 24)

    assert_match(/plays once.*does not loop/m, build_error { songs :music, [both] })
  end

  def test_saying_plays_once_with_anything_but_true_or_false_is_a_friendly_error
    odd = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4)])], plays_once: 1)

    assert_match(/plays_once.*must be true or false/m, build_error { songs :music, [odd] })
  end

  # A sound effect plays once whatever its Score says, so one that says so is taken as it is:
  # a decoder hands over the same Score whether the game plays it as a song or as an effect.
  def test_a_sound_effect_may_say_it_plays_once
    b = Builder.new
    effect = two_notes_once
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { ping: effect }
      game_loop { sfx.play :ping if pressed(:a) }
    end
    b.finalize_program
    i = game_player.input_each_frame { |frame| frame == 3 ? [:a] : [] }.run(b.program, frames: 40)

    assert_equal [NOTES[:C4], NOTES[:E4]], i.audio.select { |entry| entry[0] == :note }.map(&:last).reject(&:zero?)
  end

  def test_a_name_the_list_does_not_have_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    assert_match(/:credits/, build_error { songs(:music, { title: song }).play :credits })
  end
end
