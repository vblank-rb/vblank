# frozen_string_literal: true

require "digest"
require "tmpdir"

# SONGS AND SOUND EFFECTS WHOSE NOTES ARE READ FROM THE DATA PACK AS THE GAME STARTS. Built
# all-in-one, Builder::PackScores reads a part's notes as the game is built and the song is a Score
# written by hand. With the pack left out (`pack_at_start: true`) the build knows how many notes a
# part can have and not one of them, so each backend makes the part's events from the start file at
# power-on (IR::StartFile::Notes).
#
# The answer key is the same song written by hand, played on the interpreter. Like PackSoundTests,
# this is played by each run that reads a file as it starts: the interpreter and the game as C,
# JavaScript and Ruby, checked against it on every frame. No cartridge is handed a file, so these
# are not in test/all/.
module PackScoresAtStartTests
  Note = VBlank::Audio::Score::Note
  Part = VBlank::Audio::Score::Part
  Score = VBlank::Audio::Score
  PackNote = VBlank::Original::PackNote

  PACK_AT_START = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # Each part's slot holds this many notes, and a shorter part ends at an END_OF_PART note.
  MOST = 10
  OWN = PackNote::PART_OWN

  # A part's notes as the records a pack holds: [at, length, key, instrument, volume] each, a
  # length of 0 for until the next note, a key of REST for a rest. Then a note that ends the part,
  # and filler after it that no part may play.
  private def records(notes)
    ending = [PackNote::END_OF_PART, 0, 0, 0, 0]
    filler = [[5, 7, 64, OWN, 15]] * (MOST - notes.length - 1)
    [*notes, ending, *filler].flat_map { |note| [*note, 0] }.pack("v v C C C C" * MOST)
  end

  # The notes a Score written by hand holds for the same records, as the game plays them: a key no
  # voice has is a rest, and an instrument the part does not name or a volume past 15 is the
  # part's own. +instruments+ are the part's.
  private def written(notes, instruments = [])
    notes.map do |at, length, key, instrument, volume|
      Note.new(at: at, length: (length unless length.zero?), key: (key if key <= 127), instrument: instruments[instrument],
               volume: (volume if volume <= 15))
    end
  end

  # A made-up original nobody has a copy of: a build that leaves its pack out reads none.
  private def original_nowhere(folder)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest("made up"), "size" => 4096 } })
  end

  # An instrument's settings, which every pack here holds after its notes: an envelope's four
  # bytes, and the sample a held note reads back to.
  SHAPE = [255, 200, 120, 90].freeze
  HOLDS_FROM = 16
  SETTINGS_AT = 2048

  # The pack file holding +parts+ (their records by slot name), as a player's machine would make it.
  private def pack_file(parts)
    slots = parts.transform_values { |notes| records(notes) }.merge(settings: [*SHAPE, HOLDS_FROM].pack("C*"))
    VBlank::Original::Pack.holding(slots, sha1: Digest::SHA1.hexdigest("made up"), build_version: "1").to_bytes
  end

  # A game whose songs and sound effects are made by the block, which is handed a way to get a
  # part's notes by slot name: the slot's handle with the pack left out (+folder+ given), or the
  # notes written by hand. It plays song 0 on A and sound effect 0 on B.
  private def scored_game(parts, folder: nil, instruments: {}, &scores)
    test = self
    b = VBlank::Builder.new(options: folder ? PACK_AT_START : VBlank::Cartridge::Options.new)
    from = folder && original_nowhere(folder)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = from && data_pack(from: from, version: "1") do |slots|
        parts.each_key.with_index { |name, place| slots.notes name, at: place * MOST * PackNote::BYTES, count: MOST }
        slots.numbers :settings, at: SETTINGS_AT, count: SHAPE.length + 1, width: :byte, signed: false
      end
      notes_of = lambda do |name|
        named = instruments.fetch(name, [])
        pack ? pack[name].notes(instruments: named) : test.written_notes(parts.fetch(name), named)
      end
      # An instrument's settings from the pack too, or the same numbers written by hand.
      settings = if pack
                   { envelope: pack[:settings].envelope(0), holds_from: pack[:settings].number(SHAPE.length) }
                 else
                   { envelope: VBlank::Audio::Envelope.new(**%i[attack decay sustain release].zip(SHAPE).to_h), holds_from: HOLDS_FROM }
                 end
      made = instance_exec(notes_of, settings, &scores)
      music = songs :music, made.fetch(:songs)
      effects = (sound_effects :sfx, made[:effects] if made[:effects])
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
        effects.play 0 if effects && pressed(:b)
      end
    end
    b.finalize_program
    b.program
  end

  # Called back from the game's block, so it is public.
  def written_notes(notes, instruments) = written(notes, instruments)

  # The game with its pack left out, handed its pack, is heard as the game written by hand is: the
  # same sound log and the same mixed samples, on each of +buttons+ pressed once.
  private def assert_plays_as_written(parts, frames:, buttons: %i[a], instruments: {}, &scores)
    Dir.mktmpdir do |folder|
      by_hand = scored_game(parts, instruments: instruments, &scores)
      left_out = scored_game(parts, folder: folder, instruments: instruments, &scores)
      buttons.each do |button|
        once = ->(frame) { frame == 1 ? [button] : [] }
        wanted = game_player.input_each_frame(&once).run(by_hand, frames: frames)
        played = game_player.hand_file(pack_file(parts)).input_each_frame(&once).run(left_out, frames: frames)

        refute_empty wanted.audio.select { |entry| entry.first == :note }, "the song written by hand plays notes on #{button}"
        assert_equal wanted.audio, played.audio, "the sound log on #{button}"
        assert_equal wanted.mixed_sound, played.mixed_sound, "the mixed sound on #{button}"
      end
    end
  end

  MELODY = [[0, 12, 72, OWN, OWN], [12, 0, 76, OWN, 9], [24, 12, PackNote::REST, OWN, OWN], [36, 24, 79, OWN, 15],
            [72, 12, 67, OWN, OWN]].freeze
  BASS = [[0, 48, 48, OWN, OWN], [48, 48, 43, OWN, 6]].freeze

  def test_a_song_read_as_the_game_starts_plays_as_the_same_song_written_by_hand
    assert_plays_as_written({ melody: MELODY, bass: BASS }, frames: 90) do |notes_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody), volume: 12), Part.new(notes: notes_of.(:bass), volume: 10)],
                          tempo: 150, length: 96, plays_once: true)] }
    end
  end

  # Records out of order, two on one tick, two that fall on one frame, a note whose length ends on
  # the next note's tick and one whose length runs past it, and notes past the song's end.
  JUMBLED = [[40, 6, 70, OWN, OWN], [0, 10, 60, OWN, OWN], [10, 30, 62, OWN, 5], [20, 0, 64, OWN, OWN], [20, 4, 65, OWN, 11],
             [21, 0, 67, OWN, OWN], [90, 30, 72, OWN, OWN], [200, 4, 74, OWN, OWN]].freeze

  def test_records_in_any_order_and_on_one_frame_play_as_the_song_written_by_hand
    assert_plays_as_written({ melody: JUMBLED }, frames: 80) do |notes_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: 96, plays_once: true)] }
    end
  end

  # A song that comes round to a point part way through. The lead holds a note across that
  # point, so it is struck again there each time round; the bass is silent there and still
  # sounding at the end, so it is silenced there; and the drum starts a hit right on it.
  LEAD = [[0, 20, 72, OWN, OWN], [20, 0, 74, OWN, OWN], [60, 0, 76, OWN, OWN]].freeze
  LOW = [[0, 8, 48, OWN, OWN], [70, 0, 50, OWN, OWN]].freeze
  DRUM = [[0, 4, 60, OWN, OWN], [36, 4, 72, OWN, 9], [48, 4, 60, OWN, OWN]].freeze
  WAVE = [[0, 12, 57, OWN, OWN], [24, 0, 60, OWN, 8], [50, 10, 64, OWN, OWN]].freeze

  def test_a_song_that_comes_round_part_way_plays_as_the_song_written_by_hand
    assert_plays_as_written({ lead: LEAD, low: LOW, drum: DRUM, wave: WAVE }, frames: 150) do |notes_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:lead), duty: :quarter, transpose: 2), Part.new(notes: notes_of.(:low), volume: 9),
                                  Part.new(notes: notes_of.(:drum), plays: :noise), Part.new(notes: notes_of.(:wave), plays: :wave)],
                          tempo: 150, length: 84, loop_from: 36)] }
    end
  end

  # What a build holding the same records refuses does not stop a game reading its player's file:
  # a key no voice has is a rest, and a volume past 15 is the part's own.
  ODD = [[0, 12, 72, OWN, OWN], [12, 12, 200, OWN, 9], [24, 12, 76, OWN, 99], [36, 12, 128, OWN, OWN], [48, 12, 79, OWN, OWN]].freeze

  def test_a_key_and_a_volume_no_part_plays_do_not_stop_the_game
    assert_plays_as_written({ melody: ODD }, frames: 70) do |notes_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody), volume: 7)], tempo: 150, length: 72, plays_once: true)] }
    end
  end

  # A sound effect's parts read their notes the same way, and it plays over the song.
  BLIP = [[0, 4, 84, OWN, OWN], [6, 4, 88, OWN, 15], [12, 6, 91, OWN, OWN]].freeze

  def test_a_sound_effect_read_as_the_game_starts_plays_as_the_same_effect_written_by_hand
    assert_plays_as_written({ melody: MELODY, blip: BLIP }, frames: 60, buttons: %i[a b]) do |notes_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: 96)],
        effects: [Score.new(parts: [Part.new(notes: notes_of.(:blip), volume: 14)], tempo: 150, length: 24, priority: 3)] }
    end
  end

  # A part that plays recordings: its notes name its own instrument, each of the instruments the
  # part names, the same one twice running across the loop, and one the part does not name,
  # which is the part's own.
  TUNE = [[0, 12, 60, OWN, OWN], [12, 12, 64, 0, 12], [24, 12, 67, 1, OWN], [36, 0, 72, 7, 9], [60, 0, 64, 1, OWN]].freeze
  PCM = (0...64).map { |at| ((at * 29) % 200) - 100 }.freeze

  def test_a_part_playing_recordings_read_as_the_game_starts_plays_as_written_by_hand
    parts = { tune: TUNE, blip: BLIP }
    named = { tune: %i[bell bass], blip: %i[horn] }
    test = self
    scores = ->(notes_of, settings) { test.declare_recorded_scores(self, notes_of, settings) }
    unless VBlank::Console.described(game_console).mixes_recordings
      return Dir.mktmpdir do |folder|
        left_out = scored_game(parts, folder: folder, instruments: named, &scores)
        assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.hand_file(pack_file(parts)).run(left_out, frames: 1) }
      end
    end

    assert_plays_as_written(parts, frames: 130, buttons: %i[a b], instruments: named, &scores)
  end

  # Called back from the game's block, so it is public: the instruments and the Scores, declared on +game+.
  # The horn's hold point and the bass's envelope are numbers of the pack as well, so a note's
  # row is made for every key and then filled from the file.
  def declare_recorded_scores(game, notes_of, settings)
    game.instrument :horn, pcm: PCM, rate: 8000, note: :C4, holds_from: settings.fetch(:holds_from)
    game.instrument :bass, pcm: PCM.reverse, rate: 8000, note: :C3, envelope: settings.fetch(:envelope)
    game.instrument :bell, pcm: PCM.rotate(9), rate: 8000, note: :C5
    { songs: [Score.new(parts: [Part.new(plays: :horn, notes: notes_of.(:tune), volume: 13)], tempo: 150, length: 72, loop_from: 48)],
      effects: [Score.new(parts: [Part.new(plays: :bell, notes: notes_of.(:blip))], tempo: 150, length: 24)] }
  end

  # Shareable, as a test class's own constants are made (test_helper.rb), since a test may run in
  # a Ractor and these are a module's.
  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  def test_the_game_without_its_pack_holds_none_of_the_notes
    Dir.mktmpdir do |folder|
      left_out = scored_game({ melody: MELODY }, folder: folder) do |notes_of|
        { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: 96, plays_once: true)] }
      end
      song = left_out.walk.find { |node| node.kind == :song }
      filled = VBlank::IR::StartFile.filled(left_out, pack_file({ melody: MELODY })).walk.find { |node| node.kind == :song }

      assert_empty song.voices.first.events
      assert_equal MELODY.count { |note| note[2] <= 127 }, filled.voices.first.events.count { |event| event[1].positive? }
    end
  end

  def test_a_score_reading_notes_as_the_game_starts_names_its_length
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        scored_game({ melody: MELODY }, folder: folder) do |notes_of|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150)] }
        end
      end
      assert_match(/length/, error.message)
    end
  end
end
