# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# THE ORIGINAL'S SONGS AS NOTES, read from the data pack (Builder::PackScores). The answer key is
# the same song written by hand as a Score: the game reading its notes from the pack must play
# exactly what the game holding them plays.
class TestPackScores < Minitest::Test
  Note = VBlank::Audio::Score::Note
  Part = VBlank::Audio::Score::Part
  Score = VBlank::Audio::Score

  # [at, length, key, volume] for each note of the melody; key nil a rest, length nil until the
  # next note, volume nil the part's own.
  MELODY = [[0, 12, 72, nil], [12, nil, 76, 9], [24, 12, nil, nil], [36, 24, 79, 15], [72, 12, 67, nil]].freeze
  BASS = [[0, 48, 48, nil], [48, 48, 43, 6]].freeze
  # Each part's slot holds this many notes, and a shorter part ends at an END_OF_PART note.
  MOST = 8
  MELODY_AT = 0x10
  BASS_AT = MELODY_AT + (MOST * 8)

  # A part's notes as Original::PackNote records, ended with an END_OF_PART note and zeros after it.
  private def records(notes)
    own = VBlank::Original::PackNote::PART_OWN
    written = notes.map do |at, length, key, volume|
      [at, length || 0, key || VBlank::Original::PackNote::REST, own, volume || own, 0]
    end
    filler = [[VBlank::Original::PackNote::END_OF_PART, 0, 0, 0, 0, 0]] * (MOST - notes.length)
    (written + filler).flatten.pack("v v C C C C" * MOST)
  end

  private def original(folder)
    copy = "\0".b * (BASS_AT + (MOST * 8))
    copy[MELODY_AT, MOST * 8] = records(MELODY)
    copy[BASS_AT, MOST * 8] = records(BASS)
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # A game playing one song of two square parts: from the pack when +from+ is given, by hand otherwise.
  private def song_game(from = nil)
    b = Builder.new
    b.instance_eval do
      pack = if from
               data_pack from: from, version: "1" do |slots|
                 slots.notes :melody, at: MELODY_AT, count: MOST
                 slots.notes :bass, at: BASS_AT, count: MOST
               end
             end
      melody = pack ? pack[:melody] : MELODY.map { |at, length, key, volume| Note.new(at: at, length: length, key: key, volume: volume) }
      bass = pack ? pack[:bass].notes : BASS.map { |at, length, key, volume| Note.new(at: at, length: length, key: key, volume: volume) }
      music = songs :music, [Score.new(parts: [Part.new(notes: melody, volume: 12), Part.new(notes: bass, volume: 10)],
                                       tempo: 150, plays_once: true)]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_song_from_the_pack_plays_as_the_same_song_written_by_hand
    Dir.mktmpdir do |folder|
      wanted = game_player.run(song_game, frames: 90).audio
      played = game_player.run(song_game(original(folder)), frames: 90).audio

      refute_empty wanted.select { |entry| entry.first == :note }, "the song written by hand plays notes"
      assert_equal wanted, played
    end
  end

  def test_a_note_naming_an_instrument_the_part_does_not_name_is_refused
    Dir.mktmpdir do |folder|
      from = original_with_instrument(folder)
      error = assert_raises(ArgumentError) do
        b = Builder.new
        b.instance_eval do
          pack = data_pack from: from, version: "1" do |slots|
            slots.notes :melody, at: MELODY_AT, count: MOST
          end
          songs :music, [Score.new(parts: [Part.new(notes: pack[:melody].notes(instruments: []))])]
        end
      end

      assert_includes error.message, "instrument 2"
    end
  end

  # The made-up original with its first melody note naming instrument 2.
  private def original_with_instrument(folder)
    original(folder)
    path = File.join(folder, "made_up.bin")
    copy = File.binread(path)
    copy.setbyte(MELODY_AT + 5, 2)
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  def test_notes_from_a_slot_of_another_shape_are_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :melody, at: MELODY_AT, count: MOST, width: :byte, signed: false
        end[:melody].notes
      end

      assert_includes error.message, "slots.notes"
    end
  end

  def test_a_build_reading_its_pack_as_it_starts_is_told_it_is_not_made_yet
    Dir.mktmpdir do |folder|
      b = Builder.new(options: VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true))
      pack = b.data_pack(from: original(folder), version: "1") { |slots| slots.notes :melody, at: MELODY_AT, count: MOST }
      error = assert_raises(ArgumentError) { b.songs :music, [Score.new(parts: [Part.new(notes: pack[:melody])])] }

      assert_includes error.message, "not made that way yet"
    end
  end
end
