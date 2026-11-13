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
  BASS_AT = MELODY_AT + (MOST * VBlank::Original::PackNote::BYTES)

  # A part's notes as Original::PackNote records, ended with an END_OF_PART note and zeros after it.
  private def records(notes)
    record = VBlank::Original::PackNote
    written = notes.map do |at, length, key, volume|
      [at, length || 0, key || record::REST, record::PART_OWN, volume || record::PART_OWN]
    end
    record.bytes_of(written, count: MOST)
  end

  private def original(folder)
    copy = "\0".b * (BASS_AT + (MOST * VBlank::Original::PackNote::BYTES))
    copy[MELODY_AT, MOST * VBlank::Original::PackNote::BYTES] = records(MELODY)
    copy[BASS_AT, MOST * VBlank::Original::PackNote::BYTES] = records(BASS)
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

  # A COLOR SOUND DRIVER'S NOTES, with their voices' settings (`slots.voiced_notes`): a square
  # part whose notes give the voice's period, an envelope, a duty, vibrato and a slide, and a wave
  # part whose notes give periods, vibrato and a shade between the speakers. Each record is [at,
  # length, key, volume, its settings as Original::PackNote keeps them], beside the note written by
  # hand. Played to frame 80, short of the song's end.
  OWN = VBlank::Original::PackNote::PART_OWN
  VOICED_LEAD = [
    [[0, 10, 0, OWN, { pitch_number: 1750, fade: 3, duty: 0 }], { pitch_number: 1750, decay: 3, duty: %i[eighth] * 4 }],
    [[12, 10, 72, 9, { vibrato: 4 | (2 << 4) | (2 << 8) }], { key: 72, volume: 9, vibrato: { depth: 4, speed: 3, after: 2 } }],
    [[24, 10, 0, OWN, { pitch_number: 1800, slide: 0x23 }], { pitch_number: 1800, slide_up: { every: 2, shift: 3 } }],
    [[36, 10, 74, OWN, { slide: 0x1A }], { key: 74, slide_down: { every: 1, shift: 2 } }],
    [[48, 10, 76, 4, { fade: 0x0A, duty: 0x88 }], { key: 76, volume: 4, swell: 2, duty: %i[eighth half eighth half] }],
    [[72, 12, 79, OWN, { shade: -32 }], { key: 79, pan: Rational(-1, 2) }]
  ].freeze
  VOICED_WAVE = [
    [[0, 30, 0, OWN, { pitch_number: 1500, vibrato: 2 }], { pitch_number: 1500, vibrato: { depth: 2, speed: 1, after: 0 } }],
    [[36, 30, 60, 8, { shade: 20 }], { key: 60, volume: 8, pan: Rational(20, 64) }]
  ].freeze
  VOICED_AT = 0x300
  # Two waves of sixteen bytes in the copy, two steps a byte; a part can play the second.
  WAVES = [(0...16).map { |at| at * 17 }, (0...16).map { |at| ((15 - at) << 4) | (at % 7) }].freeze
  WAVES_AT = 0x200

  private def voiced_original(folder)
    record = VBlank::Original::PackNote
    copy = "\0".b * (VOICED_AT + (2 * MOST * record::VOICED_BYTES))
    copy[WAVES_AT, 32] = WAVES.flatten.pack("C*")
    [VOICED_LEAD, VOICED_WAVE].each_with_index do |notes, place|
      tuples = notes.map { |(at, length, key, volume, settings), _| [at, length, key, OWN, volume, nil, nil, nil, settings] }
      copy[VOICED_AT + (place * MOST * record::VOICED_BYTES), MOST * record::VOICED_BYTES] = record.bytes_of(tuples, count: MOST, voiced: true)
    end
    path = File.join(folder, "made_up_voiced.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The song of those two parts: from the pack when +from+ is given, by hand otherwise. With
  # +wave_from_copy+ the wave part plays the copy's second wave (`pack[:waves].wave(1)`, or its
  # 32 steps written out), else the triangle.
  private def voiced_song_game(from = nil, wave_from_copy: false)
    hand = ->(notes) { notes.map { |(at, length, *), words| Note.new(at: at, length: (length unless length.zero?), **words) } }
    b = Builder.new
    b.instance_eval do
      pack = if from
               data_pack from: from, version: "1" do |slots|
                 slots.numbers :waves, at: WAVES_AT, count: 32, width: :byte, signed: false
                 slots.voiced_notes :lead, at: VOICED_AT, count: MOST
                 slots.voiced_notes :wave, at: VOICED_AT + (MOST * VBlank::Original::PackNote::VOICED_BYTES), count: MOST
               end
             end
      lead = pack ? pack[:lead].notes : hand.(VOICED_LEAD)
      pad = pack ? pack[:wave] : hand.(VOICED_WAVE)
      wave = if !wave_from_copy then :triangle
             elsif pack then pack[:waves].wave(1)
             else WAVES[1].flat_map { |byte| [byte >> 4, byte & 0xF] }
             end
      music = songs :music, [Score.new(parts: [Part.new(notes: lead, duty: :quarter), Part.new(notes: pad, plays: wave)],
                                       tempo: 150, plays_once: true, length: 90)]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_notes_with_their_voices_settings_from_the_pack_play_as_written_by_hand
    Dir.mktmpdir do |folder|
      wanted = game_player.run(voiced_song_game, frames: 80).audio
      played = game_player.run(voiced_song_game(voiced_original(folder)), frames: 80).audio

      refute_empty wanted.select { |entry| entry.first == :note }, "the song written by hand plays notes"
      assert_equal wanted, played
    end
  end

  # A DRUM WHOSE HITS RATTLE ON SOME NOTES AND A WAVE PART THAT CHANGES WAVE, from voiced records
  # (Original::PackNote's bytes 25 and 26), as a Game Boy driver sets NR43's bit 3 and the wave for
  # each note it strikes. A record's wave is one of the part's (`notes(waves: [...])`): a wave of
  # the copy, a shape, or the copy's other wave. A rest's settings mean nothing. Its twin read as
  # the game starts is in test/pack_scores_at_start_tests.rb.
  RATTLING = [
    [[0, 6, 60, OWN, { metallic: 1 }], { key: 60, metallic: true }],
    [[8, 6, 62, OWN, { metallic: 0 }], { key: 62, metallic: false }],
    [[16, 6, 64, OWN, {}], { key: 64 }],
    [[24, 6, 60, OWN, { metallic: 1 }], { key: 60, metallic: true }]
  ].freeze
  WAVE_TURNS = [
    [[0, 6, 57, OWN, { wave: 0 }], { key: 57, wave: :wave_0 }],
    [[8, 6, 59, OWN, { wave: 1 }], { key: 59, wave: :sine }],
    [[16, 6, 60, OWN, {}], { key: 60 }],
    [[24, 6, 62, OWN, { wave: 2 }], { key: 62, wave: :wave_1 }]
  ].freeze

  private def rattling_original(folder)
    record = VBlank::Original::PackNote
    copy = "\0".b * (VOICED_AT + (2 * MOST * record::VOICED_BYTES))
    copy[WAVES_AT, 32] = WAVES.flatten.pack("C*")
    [RATTLING, WAVE_TURNS].each_with_index do |notes, place|
      tuples = notes.map { |(at, length, key, volume, settings), _| [at, length, key, OWN, volume, nil, nil, nil, settings] }
      copy[VOICED_AT + (place * MOST * record::VOICED_BYTES), MOST * record::VOICED_BYTES] = record.bytes_of(tuples, count: MOST, voiced: true)
    end
    path = File.join(folder, "made_up_rattling.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The copy's wave +index+ as the 32 steps a note written by hand names.
  private def copy_wave_steps(index) = WAVES[index].flat_map { |byte| [byte >> 4, byte & 0xF] }

  # The song of the drum and the wave part: from the pack when +from+ is given, by hand otherwise.
  private def rattling_game(from = nil)
    steps = { wave_0: copy_wave_steps(0), wave_1: copy_wave_steps(1) }
    hand = lambda do |notes|
      notes.map do |(at, length, *), words|
        Note.new(at: at, length: length, **words.merge(words[:wave] ? { wave: steps.fetch(words[:wave], words[:wave]) } : {}))
      end
    end
    b = Builder.new
    b.instance_eval do
      pack = if from
               data_pack from: from, version: "1" do |slots|
                 slots.numbers :waves, at: WAVES_AT, count: 32, width: :byte, signed: false
                 slots.voiced_notes :drum, at: VOICED_AT, count: MOST
                 slots.voiced_notes :pad, at: VOICED_AT + (MOST * VBlank::Original::PackNote::VOICED_BYTES), count: MOST
               end
             end
      drum = pack ? pack[:drum].notes : hand.(RATTLING)
      pad = pack ? pack[:pad].notes(waves: [pack[:waves].wave(0), :sine, pack[:waves].wave(1)]) : hand.(WAVE_TURNS)
      music = songs :music, [Score.new(parts: [Part.new(notes: drum, plays: :noise), Part.new(notes: pad, plays: :sawtooth)],
                                       tempo: 150, length: 40)]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_drum_that_rattles_and_a_wave_part_that_changes_wave_from_the_pack_play_as_written_by_hand
    Dir.mktmpdir do |folder|
      wanted = game_player.run(rattling_game, frames: 36).audio
      played = game_player.run(rattling_game(rattling_original(folder)), frames: 36).audio

      assert_equal [true, false, false, true], wanted.select { |kind, hit| kind == :noise && hit }.map { |_, hit| hit[:metallic] }
      assert_equal [copy_wave_steps(0), :sine, :sawtooth, copy_wave_steps(1)],
                   wanted.select { |kind, wave| kind == :wave && wave }.map { |_, wave| wave[:shape] }
      assert_equal wanted, played
    end
  end

  # A WAVE OF THE COPY'S (`plays: pack[:waves].wave(1)`), as a Color or Advance driver keeps its
  # wave voice's patterns, sixteen bytes each. Its twin read as the game starts is in
  # test/pack_scores_at_start_tests.rb.
  def test_a_wave_part_playing_a_wave_from_the_pack_plays_as_written_by_hand
    Dir.mktmpdir do |folder|
      wanted = game_player.run(voiced_song_game(wave_from_copy: true), frames: 80).audio
      played = game_player.run(voiced_song_game(voiced_original(folder), wave_from_copy: true), frames: 80).audio

      assert(wanted.any? { |entry| entry.first == :wave }, "the wave part plays")
      assert_equal wanted, played
    end
  end

  # A RECORDED PART BETWEEN THE SPEAKERS, as a Super Nintendo driver pans each note: shades read
  # from the pack's voiced records, heard where they sit on a console whose chip pans each voice,
  # and from both speakers where every recording is mixed into one sound.
  SHADED_TUNE = [
    [[0, 12, 60, OWN, { shade: -44 }], { key: 60, pan: -0.6875 }],
    [[12, 12, 64, 9, { shade: 46 }], { key: 64, volume: 9, pan: 0.71875 }],
    [[24, 12, 67, OWN, { shade: 0 }], { key: 67, pan: 0 }],
    [[36, 12, 72, OWN, {}], { key: 72 }]
  ].freeze
  PCM = (0...64).map { |at| ((at * 29) % 200) - 100 }.freeze

  private def shaded_original(folder)
    record = VBlank::Original::PackNote
    tuples = SHADED_TUNE.map { |(at, length, key, volume, settings), _| [at, length, key, OWN, volume, nil, nil, nil, settings] }
    copy = record.bytes_of(tuples, count: MOST, voiced: true)
    path = File.join(folder, "made_up_shaded.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  private def shaded_game(from = nil)
    hand = SHADED_TUNE.map { |(at, length, *), words| Note.new(at: at, length: length, **words) }
    b = Builder.new
    b.instance_eval do
      pack = (data_pack(from: from, version: "1") { |slots| slots.voiced_notes :tune, at: 0, count: MOST } if from)
      instrument :horn, pcm: PCM, rate: 8000, note: :C4
      music = songs :music, [Score.new(parts: [Part.new(plays: :horn, notes: pack ? pack[:tune].notes : hand, volume: 13)],
                                       tempo: 150, plays_once: true, length: 60)]
      music.play 0
      game_loop { wait_vblank }
    end
    b.finalize_program
    b.program
  end

  def test_a_recorded_part_shaded_between_the_speakers_from_the_pack_plays_as_written_by_hand
    Dir.mktmpdir do |folder|
      # The Color, which has no instruments, refuses the song.
      unless VBlank::Console.for(game_console).answers.answer(:instrument).works?
        next assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(shaded_game(shaded_original(folder)), frames: 1) }
      end

      wanted = game_player.run(shaded_game, frames: 50)
      played = game_player.run(shaded_game(shaded_original(folder)), frames: 50)

      refute_empty wanted.audio.select { |entry| entry.first == :note }, "the song written by hand plays notes"
      assert_equal wanted.audio, played.audio
    end
  end

  # A SOUND EFFECT OF PITCHES BETWEEN KEYS THAT GLIDE, as a Super Nintendo driver's effect script
  # sets the chip's pitch word under a sounding note: voiced records naming hz in 16ths and
  # GLIDES, on a recorded part, and a drum part whose hits name hz too.
  GLIDING = [
    [[0, 0, 60, OWN, { hz: 4186 }], { hz: Rational(4186, 16) }],
    [[4, 0, 60, OWN, { hz: 4410, glides: true }], { hz: Rational(4410, 16), glides: true }],
    [[8, 0, 60, OWN, { hz: 4700, glides: true }], { hz: Rational(4700, 16), glides: true }],
    [[14, 0, 0, 9, { hz: 3333 }], { hz: Rational(3333, 16), volume: 9 }],
    [[20, 10, 64, OWN, { hz: 5000, glides: true }], { hz: Rational(5000, 16), glides: true }]
  ].freeze
  HISSED = [
    [[0, 6, 60, OWN, { hz: 120_000 * 16 }], { hz: 120_000 }],
    [[10, 6, 60, OWN, { hz: 7777 }], { hz: Rational(7777, 16) }]
  ].freeze

  # GLIDING for this run's console: one whose recorded notes cannot glide
  # (Console::Description#glides_recordings) strikes each instead, in the records and by hand.
  private def gliding_notes
    return GLIDING if VBlank::Console.described(game_console).glides_recordings

    GLIDING.map { |(record, words)| [[*record.first(4), record[4].except(:glides)], words.except(:glides)] }
  end

  private def gliding_original(folder)
    record = VBlank::Original::PackNote
    copy = [gliding_notes, HISSED].map do |notes|
      tuples = notes.map { |(at, length, key, volume, settings), _| [at, length, key, OWN, volume, nil, nil, nil, settings] }
      record.bytes_of(tuples, count: MOST, voiced: true)
    end.join
    path = File.join(folder, "made_up_gliding.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :snes,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The effect of those two parts, from the pack when +from+ is given, by hand otherwise, played on A.
  private def gliding_game(from = nil, recorded: true)
    hand = ->(notes) { notes.map { |(at, length, *), words| Note.new(at: at, length: (length unless length.zero?), **words) } }
    gliding = gliding_notes
    b = Builder.new
    b.instance_eval do
      bytes = MOST * VBlank::Original::PackNote::VOICED_BYTES
      pack = if from
               data_pack(from: from, version: "1") do |slots|
                 slots.voiced_notes :glide, at: 0, count: MOST
                 slots.voiced_notes :hiss, at: bytes, count: MOST
               end
             end
      instrument :horn, pcm: PCM, rate: 8000, note: :C4 if recorded
      parts = [Part.new(plays: :noise, notes: pack ? pack[:hiss].notes : hand.(HISSED))]
      parts.unshift(Part.new(plays: :horn, notes: pack ? pack[:glide].notes : hand.(gliding), volume: 13)) if recorded
      effects = sound_effects :sfx, [Score.new(parts: parts, tempo: 150, length: 40)]
      game_loop do
        wait_vblank
        effects.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  def test_pitches_between_keys_that_glide_from_the_pack_play_as_written_by_hand
    once = ->(frame) { frame == 1 ? [:a] : [] }
    Dir.mktmpdir do |folder|
      recorded = VBlank::Console.for(game_console).answers.answer(:instrument).works?
      wanted = game_player.input_each_frame(&once).run(gliding_game(recorded: recorded), frames: 40).audio
      played = game_player.input_each_frame(&once).run(gliding_game(gliding_original(folder), recorded: recorded), frames: 40).audio

      refute_empty wanted.select { |entry| entry.first == :note }, "the effect written by hand plays notes"
      assert_equal wanted, played
    end
  end

  def test_a_voiced_note_naming_a_setting_out_of_its_range_is_refused
    Dir.mktmpdir do |folder|
      path = File.join(folder, "made_up_voiced.bin")
      voiced_original(folder)
      copy = File.binread(path)
      # The first note's pitch number made 4095, past 2047.
      copy.setbyte(VOICED_AT + 12, 0xFF)
      copy.setbyte(VOICED_AT + 13, 0x0F)
      File.binwrite(path, copy)
      from = VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                                        settings_file: File.join(folder, "made_up.yml"),
                                        releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
      error = assert_raises(ArgumentError) { voiced_song_game(from) }

      assert_includes error.message, "pitch number"
    end
  end

  # A build that reads its pack as the game starts plays the song too (test/pack_scores_at_start_tests.rb),
  # given the one thing it cannot work out without the notes.
  def test_a_build_reading_its_pack_as_it_starts_needs_the_scores_length
    Dir.mktmpdir do |folder|
      b = Builder.new(options: VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true))
      pack = b.data_pack(from: original(folder), version: "1") { |slots| slots.notes :melody, at: MELODY_AT, count: MOST }
      error = assert_raises(ArgumentError) { b.songs :music, [Score.new(parts: [Part.new(notes: pack[:melody])])] }

      assert_includes error.message, "length"
      b.songs :music, [Score.new(parts: [Part.new(notes: pack[:melody])], length: 96)]
    end
  end
end
