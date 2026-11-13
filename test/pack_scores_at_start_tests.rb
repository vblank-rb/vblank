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
  # length of 0 for until the next note, a key of REST for a rest, and a loudness in 512ths after
  # the volume where a note gives one, then its speaker and its noise clock where it gives them.
  # Then a note that ends the part, and filler after it that no part may play.
  private def records(notes)
    ending = [PackNote::END_OF_PART, 0, 0, 0, 0]
    filler = [[5, 7, 64, OWN, 15, 300, 1, 0x21]] * (MOST - notes.length - 1)
    [*notes, ending, *filler].flat_map do |at, length, key, instrument, volume, loudness, pan, clock|
      [at, length, key, instrument, volume, pan || OWN, loudness || PackNote::NO_LOUDNESS, clock || OWN, 0]
    end.pack(PackNote::LAYOUT.delete(" ") * MOST)
  end

  # The speaker a record's byte names, as a note gives it.
  SIDE_OF_BYTE = { 0 => :center, 1 => :left, 2 => :right }.freeze

  # The notes a Score written by hand holds for the same records, as the game plays them: a key no
  # voice has is a rest, and an instrument the part does not name or a volume past 15 is the
  # part's own. A loudness on a part that plays a recording is its volume, all of the recording at
  # most; elsewhere it means nothing. A speaker is the note's on a part of the console's voices, and
  # means nothing on a recorded part; one that is no speaker is the part's own. A noise clock with
  # its halvings 13 or fewer is the note's pitch, in place of its key. +instruments+ are the part's.
  private def written(notes, instruments = [], recorded: false)
    notes.map do |at, length, key, instrument, volume, loudness, pan, clock|
      volume = Rational(15 * [loudness, 512].min, 512) if recorded && loudness
      clock = ([clock & 7, clock >> 4] if clock && (clock >> 4) <= 13 && key <= 127)
      Note.new(at: at, length: (length unless length.zero?), key: (key if key <= 127 && !clock), instrument: instruments[instrument],
               volume: (volume if volume <= 15), pan: (SIDE_OF_BYTE[pan] unless recorded), noise_clock: clock)
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

  # A song's length and the tick it comes round to, two numbers of two bytes after the settings,
  # which a song can read in place of numbers of its own (`length: pack[:timing].number(0)`).
  TIMING = [84, 36].freeze
  TIMING_AT = 2064

  # Two waves of the wave voice, sixteen bytes each, two steps a byte with the earlier in the high
  # four bits, as a sound driver keeps its wave voice's patterns; a part plays one with
  # `plays: pack[:waves].wave(1)`.
  WAVES = [(0...16).map { |at| at * 17 }, (0...16).map { |at| ((15 - at) << 4) | (at % 7) }].freeze
  WAVES_AT = 2096

  # Wave +index+ of WAVES as the 32 steps a part written by hand plays.
  private def wave_steps(index) = WAVES.fetch(index).flat_map { |byte| [byte >> 4, byte & 0xF] }

  # The pack file holding +parts+ (their records by slot name), as a player's machine would make it.
  # +timing+ is what its song's length and loop hold, and with +waves+ it holds WAVES.
  private def pack_file(parts, timing: TIMING, waves: false)
    slots = parts.transform_values { |notes| records(notes) }.merge(settings: [*SHAPE, HOLDS_FROM].pack("C*"),
                                                                    timing: timing.pack("v*"))
    slots[:waves] = WAVES.flatten.pack("C*") if waves
    VBlank::Original::Pack.holding(slots, sha1: Digest::SHA1.hexdigest("made up"), build_version: "1").to_bytes
  end

  # A game whose songs and sound effects are made by the block, which is handed a way to get a
  # part's notes by slot name: the slot's handle with the pack left out (+folder+ given), or the
  # notes written by hand. It plays song 0 on A and sound effect 0 on B, or with +plays+ false
  # declares them and plays neither. With +waves+ the pack has a slot of WAVES, and the block is
  # handed a way to get one of them for a part's `plays:`, the same way.
  private def scored_game(parts, folder: nil, instruments: {}, plays: true, waves: false, &scores)
    test = self
    b = VBlank::Builder.new(options: folder ? PACK_AT_START : VBlank::Cartridge::Options.new)
    from = folder && original_nowhere(folder)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = from && data_pack(from: from, version: "1") do |slots|
        parts.each_key.with_index { |name, place| slots.notes name, at: place * MOST * PackNote::BYTES, count: MOST }
        slots.numbers :settings, at: SETTINGS_AT, count: SHAPE.length + 1, width: :byte, signed: false
        slots.numbers :timing, at: TIMING_AT, count: TIMING.length, width: :half, signed: false
        slots.numbers :waves, at: WAVES_AT, count: WAVES.flatten.length, width: :byte, signed: false if waves
      end
      wave_of = ->(index) { pack ? pack[:waves].wave(index) : test.wave_steps_by_hand(index) }
      notes_of = lambda do |name, recorded: false|
        named = instruments.fetch(name, [])
        pack ? pack[name].notes(instruments: named) : test.written_notes(parts.fetch(name), named, recorded)
      end
      # An instrument's settings from the pack too, or the same numbers written by hand.
      settings = if pack
                   { envelope: pack[:settings].envelope(0), holds_from: pack[:settings].number(SHAPE.length) }
                 else
                   { envelope: VBlank::Audio::Envelope.new(**%i[attack decay sustain release].zip(SHAPE).to_h), holds_from: HOLDS_FROM }
                 end
      # A song's length and loop from the pack, or the same numbers written by hand.
      timing = pack ? { length: pack[:timing].number(0), loop_from: pack[:timing].number(1) } : { length: TIMING[0], loop_from: TIMING[1] }
      # A block may be a lambda, which takes only the arguments it names.
      made = instance_exec(notes_of, settings, timing, *(wave_of if waves), &scores)
      music = songs :music, made.fetch(:songs)
      effects = (sound_effects :sfx, made[:effects] if made[:effects])
      game_loop do
        wait_vblank
        music.play 0 if plays && pressed(:a)
        effects.play 0 if plays && effects && pressed(:b)
      end
    end
    b.finalize_program
    b.program
  end

  # Called back from the game's block, so it is public.
  def written_notes(notes, instruments, recorded) = written(notes, instruments, recorded: recorded)

  # Called back from the game's block, so it is public.
  def wave_steps_by_hand(index) = wave_steps(index)

  # The game with its pack left out, handed its pack, is heard as the game written by hand is: the
  # same sound log and the same mixed samples, on each of +buttons+ pressed once.
  private def assert_plays_as_written(parts, frames:, buttons: %i[a], instruments: {}, waves: false, &scores)
    Dir.mktmpdir do |folder|
      by_hand = scored_game(parts, instruments: instruments, waves: waves, &scores)
      left_out = scored_game(parts, folder: folder, instruments: instruments, waves: waves, &scores)
      buttons.each do |button|
        once = ->(frame) { frame == 1 ? [button] : [] }
        wanted = game_player.input_each_frame(&once).run(by_hand, frames: frames)
        played = game_player.hand_file(pack_file(parts, waves: waves)).input_each_frame(&once).run(left_out, frames: frames)

        refute_empty wanted.audio.select { |entry| entry.first == :note }, "the song written by hand plays notes on #{button}"
        assert_equal wanted.audio, played.audio, "the sound log on #{button}"
        assert_equal wanted.mixed_sound, played.mixed_sound, "the mixed sound on #{button}"
      end
    end
  end

  # The note at tick 36 gives a loudness, which a square part does not take.
  MELODY = [[0, 12, 72, OWN, OWN], [12, 0, 76, OWN, 9], [24, 12, PackNote::REST, OWN, OWN], [36, 24, 79, OWN, 15, 100],
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

  # A WAVE OF THE PACK'S, read as the game starts (`plays: pack[:waves].wave(1)`): the song's wave
  # part reads its notes from the pack too, and the sound effect's, written in the game, plays the
  # other wave. Each is heard as the same wave's 32 steps written by hand. A build for a computer
  # playing as a console whose voices read sound memory (the PlayStation) makes that memory as the
  # game is built, and refuses the wave in plain words.
  def test_a_wave_part_playing_a_wave_from_the_pack_read_as_the_game_starts_plays_as_written_by_hand
    parts = { lead: LEAD, wave: WAVE }
    scores = lambda do |notes_of, _settings, _timing, wave_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:lead)), Part.new(notes: notes_of.(:wave), plays: wave_of.(1))],
                          tempo: 150, length: 84, loop_from: 36)],
        effects: [Score.new(parts: [Part.new(notes: [Note.new(at: 0, length: 8, key: 69), Note.new(at: 12, key: 76)], plays: wave_of.(0))],
                            tempo: 150, length: 24)] }
    end
    unless VBlank::Testing.checked? && VBlank::Console.described(game_console).voices_read_sound_memory
      return assert_plays_as_written(parts, frames: 120, buttons: %i[a b], waves: true, &scores)
    end

    Dir.mktmpdir do |folder|
      left_out = scored_game(parts, folder: folder, waves: true, &scores)
      error = assert_raises(VBlank::BuildError) { game_player.hand_file(pack_file(parts, waves: true)).run(left_out, frames: 1) }
      assert_includes error.message, "sound memory"
    end
  end

  # A NOTE'S SPEAKER AND ITS NOISE CLOCK, as a sound driver sets them for each note it strikes. A
  # square part takes each record's speaker (0 both, 1 the left, 2 the right) over its own, and one
  # that is no speaker is the part's; a part on the noise voice takes each record's clock (the
  # divider in the low three bits, the halvings in the high four) in place of its key, and one
  # whose halvings are past 13 plays its key. The lead holds a note on the left across the loop.
  SIDED = [[0, 10, 72, OWN, OWN, nil, 1], [10, 20, 74, OWN, OWN, nil, 2], [30, 10, 76, OWN, OWN, nil, 0],
           [40, 10, 77, OWN, OWN, nil, OWN], [50, 0, 79, OWN, OWN, nil, 9], [70, 0, 72, OWN, OWN, nil, 1]].freeze
  CLOCKED = [[0, 6, 60, OWN, OWN, nil, nil, 0x13], [8, 6, 60, OWN, OWN, nil, 2, 0x37], [16, 6, 64, OWN, OWN, nil, nil, OWN],
             [24, 6, 64, OWN, OWN, nil, nil, 0xD7], [32, 6, 64, OWN, OWN, nil, nil, 0xF2], [40, 6, PackNote::REST, OWN, OWN, nil, nil, 0x21],
             [48, 6, 70, OWN, 9, nil, 1, 0x0D]].freeze

  def test_a_notes_speaker_and_noise_clock_read_as_the_game_starts_play_as_written_by_hand
    assert_plays_as_written({ lead: SIDED, drum: CLOCKED }, frames: 150) do |notes_of|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:lead), pan: :right), Part.new(notes: notes_of.(:drum), plays: :noise)],
                          tempo: 150, length: 84, loop_from: 20)] }
    end
  end

  # A SONG WHOSE LENGTH AND LOOP ARE IN THE PACK TOO, as a sound driver's song is: where it ends and
  # where it comes round are commands in its data, which the unpacking runs and writes as numbers.
  # The build knows only the most it can last (`longest:`).
  def test_a_songs_length_and_loop_read_as_the_game_starts_play_as_the_same_numbers_written_by_hand
    assert_plays_as_written({ lead: LEAD, low: LOW, drum: DRUM, wave: WAVE }, frames: 200) do |notes_of, _settings, timing|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:lead), duty: :quarter, transpose: 2), Part.new(notes: notes_of.(:low), volume: 9),
                                  Part.new(notes: notes_of.(:drum), plays: :noise), Part.new(notes: notes_of.(:wave), plays: :wave)],
                          tempo: 150, longest: 300, **timing)] }
    end
  end

  # A song that plays once ends where the pack says, and a sound effect's length can be read too.
  def test_a_song_that_plays_once_ends_where_the_pack_says
    assert_plays_as_written({ melody: MELODY, blip: BLIP }, frames: 120, buttons: %i[a b]) do |notes_of, _settings, timing|
      { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: timing.fetch(:length), longest: 200,
                          plays_once: true)],
        effects: [Score.new(parts: [Part.new(notes: notes_of.(:blip))], tempo: 150, length: timing.fetch(:loop_from), longest: 50)] }
    end
  end

  # The file is the player's: a length past the most the build made room for is that most, and a
  # loop on or past the end comes round to the start.
  def test_a_length_past_the_longest_and_a_loop_past_the_end_do_not_stop_the_game
    Dir.mktmpdir do |folder|
      by_hand = scored_game({ melody: MELODY }) do |notes_of|
        { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: 60)] }
      end
      left_out = scored_game({ melody: MELODY }, folder: folder) do |notes_of, _settings, timing|
        { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, longest: 60, **timing)] }
      end
      once = ->(frame) { frame == 1 ? [:a] : [] }
      wanted = game_player.input_each_frame(&once).run(by_hand, frames: 150)
      played = game_player.hand_file(pack_file({ melody: MELODY }, timing: [500, 70])).input_each_frame(&once).run(left_out, frames: 150)

      assert_equal wanted.audio, played.audio
    end
  end

  def test_a_length_from_the_pack_names_the_longest_the_song_can_be
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        scored_game({ melody: MELODY }, folder: folder) do |notes_of, _settings, timing|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, **timing)] }
        end
      end
      assert_match(/longest:/, error.message)
    end
  end

  def test_a_length_from_the_pack_beside_a_part_written_in_the_game_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        scored_game({ melody: MELODY }, folder: folder) do |notes_of, _settings, timing|
          { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody)), Part.new(notes: [Note.new(at: 0, key: 60)])],
                              tempo: 150, longest: 200, **timing)] }
        end
      end
      assert_match(/every part/, error.message)
    end
  end

  # A PORT WITH A SOUND DRIVER OF ITS OWN, which VBlank knows nothing of, plays its song through the
  # pack alone: its unpacking runs the driver's commands forward and writes the notes they play
  # and the song's length, a tick a frame, as a driver that runs once a frame plays them. The
  # made-up driver's commands: OWN_NOTE, a key and how many frames; OWN_REST and how many frames;
  # OWN_FINE, the end.
  OWN_NOTE = 1
  OWN_REST = 2
  OWN_FINE = 0xFF
  OWN_TUNE = [[72, 10], [nil, 6], [76, 8], [79, 12], [nil, 4], [67, 20]].freeze
  OWN_STREAM_AT = 0x100
  # A Score whose tick is a frame: a beat of one tick, 3600 beats a minute (Audio::Score::FRAME_RATE).
  A_TICK_A_FRAME = { tempo: 3600, ticks_per_beat: 1 }.freeze

  private def own_driver_copy
    copy = "\0".b * 4096
    stream = OWN_TUNE.flat_map { |key, frames| key ? [OWN_NOTE, key, frames] : [OWN_REST, frames] } + [OWN_FINE]
    copy[OWN_STREAM_AT, stream.length] = stream.pack("C*")
    copy
  end

  # The game reading the driver's song from its pack as it starts, and its pack's unpacking.
  private def own_driver_game(folder)
    from = original_nowhere(folder)
    b = VBlank::Builder.new(options: PACK_AT_START)
    made = nil
    b.instance_eval do
      screen :bitmap
      enable_sound
      made = data_pack(from: from, version: "1") do |slots|
        slots.notes :tune, count: MOST
        slots.numbers :tune_length, count: 1, width: :half, signed: false
        slots.fill_from_copy do |copy, pack|
          at = OWN_STREAM_AT
          tick = 0
          record = 0
          command = copy.byte(at)
          while command != OWN_FINE
            if command == OWN_NOTE
              frames = copy.byte(at + 2)
              pack[:tune][record] = tick
              pack[:tune][record + 1] = tick / 256
              pack[:tune][record + 2] = frames
              pack[:tune][record + 3] = 0
              pack[:tune][record + 4] = copy.byte(at + 1)
              pack[:tune][record + 5] = OWN
              pack[:tune][record + 6] = OWN
              pack[:tune][record + 7] = OWN
              pack[:tune][record + 8] = 0xFF
              pack[:tune][record + 9] = 0xFF
              pack[:tune][record + 10] = OWN
              pack[:tune][record + 11] = 0
              record += PackNote::BYTES
              tick += frames
              at += 3
            else
              tick += copy.byte(at + 1)
              at += 2
            end
            command = copy.byte(at)
          end
          pack[:tune][record] = 0xFF
          pack[:tune][record + 1] = 0xFF
          pack[:tune_length][0] = tick
        end
      end
      music = songs :music, [Score.new(parts: [Part.new(notes: made[:tune].notes)], length: made[:tune_length].number(0),
                                       longest: 600, plays_once: true, **A_TICK_A_FRAME)]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    [b.program, made]
  end

  def test_a_port_with_a_sound_driver_of_its_own_plays_its_song_through_the_pack
    Dir.mktmpdir do |folder|
      program, made = own_driver_game(folder)
      unpacking = made.unpacking(release: made.original.releases.with_sha1(Digest::SHA1.hexdigest("made up")))
      unpacked = game_player.hand_file(own_driver_copy).run(unpacking.program, frames: 60)
      assert unpacking.finished_in?(unpacked), "the unpacking runs the driver's song to its end"
      file = unpacking.pack_file_in(unpacked, sha1: Digest::SHA1.hexdigest("made up"), build_version: "1")

      tick = 0
      notes = OWN_TUNE.filter_map do |key, frames|
        note = Note.new(at: tick, key: key, length: frames) if key
        tick += frames
        note
      end
      by_hand = scored_game({}) do
        { songs: [Score.new(parts: [Part.new(notes: notes)], length: tick, plays_once: true, **A_TICK_A_FRAME)] }
      end
      once = ->(frame) { frame == 1 ? [:a] : [] }
      wanted = game_player.input_each_frame(&once).run(by_hand, frames: 80)
      played = game_player.hand_file(file).input_each_frame(&once).run(program, frames: 80)

      refute_empty wanted.audio.select { |entry| entry.first == :note }
      assert_equal wanted.audio, played.audio
    end
  end

  # A DRIVER WHOSE NOTES PICK THEIR VOICES, each voice a recording of its own with its own rate, hold
  # point and envelope, as a cartridge's voice group keeps them, and each note its own loudness. A
  # port gives each voice an instrument of its own, every setting of it from the pack, and a note's
  # record names the voice it plays: no envelope or recording needs to be in the note itself. The
  # made-up driver's commands are OWN_NOTE with a key, frames and a velocity (0 to 127, a loudness
  # of four times that), OWN_REST, OWN_VOICE with a voice's number, and OWN_FINE.
  OWN_VOICE = 3
  VOICED_TUNE = [[:voice, 1], [60, 10, 127], [:rest, 4], [:voice, 0], [64, 12, 30], [67, 8, 90], [:voice, 1], [72, 20, 64]].freeze
  VOICES_AT = 0x200 # each voice: its rate (two bytes), the sample it holds from, its envelope's four bytes, a byte of nothing
  VOICE_SAMPLES_AT = 0x300
  VOICE_SAMPLES = 64
  VOICES = [[7929, 16, [255, 200, 120, 90]], [11_025, 40, [40, 230, 200, 160]]].freeze

  private def voiced_copy
    copy = "\0".b * 4096
    stream = VOICED_TUNE.flat_map do |command, *rest|
      case command
      when :voice then [OWN_VOICE, *rest]
      when :rest then [OWN_REST, *rest]
      else [OWN_NOTE, command, *rest]
      end
    end
    copy[OWN_STREAM_AT, stream.length + 1] = [*stream, OWN_FINE].pack("C*")
    VOICES.each_with_index do |(rate, holds, shape), voice|
      copy[VOICES_AT + (voice * 8), 8] = [rate, holds, *shape, 0].pack("v C C C C C C")
      copy[VOICE_SAMPLES_AT + (voice * VOICE_SAMPLES), VOICE_SAMPLES] = PCM.rotate(voice * 11).map { |level| level * (voice + 1) / 2 }.pack("c*")
    end
    copy
  end

  private def voiced_original(folder)
    path = File.join(folder, "voiced.bin")
    File.binwrite(path, voiced_copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gba,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(voiced_copy), "size" => 4096 } })
  end

  # The game reading the voiced driver's song, all-in-one or (+options+) with its pack left out.
  private def voiced_driver_game(from, options)
    b = VBlank::Builder.new(options: options)
    made = nil
    b.instance_eval do
      screen :bitmap
      enable_sound mix_rate: 13_379
      made = data_pack(from: from, version: "1") do |slots|
        slots.notes :tune, count: MOST
        slots.numbers :tune_length, count: 1, width: :half, signed: false
        VOICES.each_index do |voice|
          slots.samples :"pcm_#{voice}", at: VOICE_SAMPLES_AT + (voice * VOICE_SAMPLES), count: VOICE_SAMPLES
          slots.numbers :"rate_#{voice}", at: VOICES_AT + (voice * 8), count: 1, width: :half, signed: false
          slots.numbers :"voice_#{voice}", at: VOICES_AT + (voice * 8) + 2, count: 5, width: :byte, signed: false
        end
        slots.fill_from_copy do |copy, pack|
          at = OWN_STREAM_AT
          tick = 0
          record = 0
          voice = 0
          command = copy.byte(at)
          while command != OWN_FINE
            if command == OWN_NOTE
              frames = copy.byte(at + 2)
              loudness = copy.byte(at + 3) * 4
              pack[:tune][record] = tick
              pack[:tune][record + 1] = tick / 256
              pack[:tune][record + 2] = frames
              pack[:tune][record + 3] = 0
              pack[:tune][record + 4] = copy.byte(at + 1)
              pack[:tune][record + 5] = voice
              pack[:tune][record + 6] = OWN
              pack[:tune][record + 7] = OWN
              pack[:tune][record + 8] = loudness
              pack[:tune][record + 9] = loudness / 256
              pack[:tune][record + 10] = OWN
              pack[:tune][record + 11] = 0
              record += PackNote::BYTES
              tick += frames
              at += 4
            elsif command == OWN_VOICE
              voice = copy.byte(at + 1)
              at += 2
            else
              tick += copy.byte(at + 1)
              at += 2
            end
            command = copy.byte(at)
          end
          pack[:tune][record] = 0xFF
          pack[:tune][record + 1] = 0xFF
          pack[:tune_length][0] = tick
        end
      end
      VOICES.each_index do |voice|
        settings = made[:"voice_#{voice}"]
        instrument :"voice_#{voice}", pcm: made[:"pcm_#{voice}"], note: :C4, rate: made[:"rate_#{voice}"].number(0),
                                      holds_from: settings.number(0), envelope: settings.as_numbers(at: 1, count: 4, width: :byte, signed: false).envelope(0)
      end
      music = songs :music, [Score.new(parts: [Part.new(plays: :voice_0, notes: made[:tune].notes(instruments: %i[voice_0 voice_1]))],
                                       length: made[:tune_length].number(0), longest: 600, plays_once: true, **A_TICK_A_FRAME)]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    [b.program, made]
  end

  def test_a_drivers_voices_each_with_its_own_recording_and_envelope_play_alike_all_in_one_and_from_the_pack
    Dir.mktmpdir do |folder|
      from = voiced_original(folder)
      whole, = voiced_driver_game(from, VBlank::Cartridge::Options.new)
      unless VBlank::Console.described(game_console).mixes_recordings
        next assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(whole, frames: 1) }
      end

      left_out, made = voiced_driver_game(from, PACK_AT_START)
      unpacking = made.unpacking(release: made.original.releases.with_sha1(Digest::SHA1.hexdigest(voiced_copy)))
      unpacked = game_player.hand_file(voiced_copy).run(unpacking.program, frames: 60)
      assert unpacking.finished_in?(unpacked), "the unpacking runs the driver's song to its end"
      file = unpacking.pack_file_in(unpacked, sha1: Digest::SHA1.hexdigest(voiced_copy), build_version: "1")

      once = ->(frame) { frame == 1 ? [:a] : [] }
      wanted = game_player.input_each_frame(&once).run(whole, frames: 80)
      played = game_player.hand_file(file).input_each_frame(&once).run(left_out, frames: 80)

      assert wanted.mixed_sound.flatten.any? { |level| level != 0 }, "the all-in-one build plays the driver's song"
      assert_equal wanted.audio, played.audio
      assert_equal wanted.mixed_sound, played.mixed_sound
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
  # which is the part's own. A speaker means nothing on a recorded part.
  TUNE = [[0, 12, 60, OWN, OWN], [12, 12, 64, 0, 12, nil, 1], [24, 12, 67, 1, OWN], [36, 0, 72, 7, 9], [60, 0, 64, 1, OWN]].freeze
  PCM = (0...64).map { |at| ((at * 29) % 200) - 100 }.freeze

  def test_a_part_playing_recordings_read_as_the_game_starts_plays_as_written_by_hand
    parts = { tune: TUNE, blip: BLIP }
    named = { tune: %i[bell bass], blip: %i[horn] }
    test = self
    scores = ->(notes_of, settings, _timing) { test.declare_recorded_scores(self, notes_of, settings) }
    unless VBlank::Console.described(game_console).mixes_recordings
      return Dir.mktmpdir do |folder|
        left_out = scored_game(parts, folder: folder, instruments: named, &scores)
        assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.hand_file(pack_file(parts)).run(left_out, frames: 1) }
      end
    end

    assert_plays_as_written(parts, frames: 130, buttons: %i[a b], instruments: named, &scores)
  end

  # A RECORDED PART'S LOUDNESS IN 512THS, as a cartridge's sound engine mixes it: a quiet note, two
  # notes as loud as each other held across the loop, one given a volume and the same loudness as
  # that volume, one past all of the recording, and one of none.
  LOUD_TUNE = [[0, 12, 60, OWN, OWN, 37], [12, 12, 64, OWN, OWN, 241], [24, 12, 67, OWN, 15], [36, 0, 72, OWN, OWN, 512],
               [48, 0, 72, OWN, OWN, 512], [56, 0, 65, OWN, 3, 900], [64, 4, 62, OWN, OWN, 0]].freeze

  def test_a_recorded_parts_loudness_in_512ths_plays_as_the_volume_with_a_fraction
    test = self
    scores = ->(notes_of, _settings, _timing) { test.declare_loud_scores(self, notes_of) }
    # A loudness is only a part's volume, which every console that plays an instrument takes:
    # the Genesis plays this song, and the Color, which has no instruments, refuses it.
    unless VBlank::Console.for(game_console).answers.answer(:instrument).works?
      return Dir.mktmpdir do |folder|
        left_out = scored_game({ loud: LOUD_TUNE }, folder: folder, &scores)
        assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.hand_file(pack_file({ loud: LOUD_TUNE })).run(left_out, frames: 1) }
      end
    end

    assert_plays_as_written({ loud: LOUD_TUNE }, frames: 150, &scores)
  end

  # Called back from the game's block, so it is public.
  def declare_loud_scores(game, notes_of)
    game.instrument :horn, pcm: PCM, rate: 8000, note: :C4
    { songs: [Score.new(parts: [Part.new(plays: :horn, notes: notes_of.(:loud, recorded: true), volume: 13)], tempo: 150, length: 72,
                        loop_from: 40)] }
  end

  # Called back from the game's block, so it is public: the instruments and the Scores, declared on +game+.
  # The horn's hold point and the bass's envelope are numbers of the pack as well, so a note's
  # row is made for every key and then filled from the file.
  def declare_recorded_scores(game, notes_of, settings)
    game.instrument :horn, pcm: PCM, rate: 8000, note: :C4, holds_from: settings.fetch(:holds_from)
    game.instrument :bass, pcm: PCM.reverse, rate: 8000, note: :C3, envelope: settings.fetch(:envelope)
    game.instrument :bell, pcm: PCM.rotate(9), rate: 8000, note: :C5
    { songs: [Score.new(parts: [Part.new(plays: :horn, notes: notes_of.(:tune, recorded: true), volume: 13)], tempo: 150, length: 72,
                        loop_from: 48)],
      effects: [Score.new(parts: [Part.new(plays: :bell, notes: notes_of.(:blip, recorded: true))], tempo: 150, length: 24)] }
  end

  # NOTES WITH THEIR VOICE'S SETTINGS (`slots.voiced_notes`), as a Game Boy sound driver sets them
  # for each note it strikes: a pitch number in place of a key, a fade, a duty, vibrato, a slide on
  # the first square, a shade between the speakers. Each record is [at, length, key, volume, its
  # settings by Original::PackNote::NAMES' names, each the number its byte keeps], and beside it
  # the note written by hand for it. A setting a part's voice does not have, or one out of its
  # range, is the part's own; a note whose slide and vibrato would both move holds its vibrato.
  EIGHTHS = %i[eighth eighth eighth eighth].freeze
  VOICED_LEAD = [
    [[0, 10, 0, OWN, { pitch_number: 1750, fade: 3, duty: 0 }], { pitch_number: 1750, decay: 3, duty: EIGHTHS }],
    [[12, 10, 72, 9, { vibrato: 4 | (2 << 4) | (2 << 8) }], { key: 72, volume: 9, vibrato: { depth: 4, speed: 3, after: 2 } }],
    [[24, 10, 0, OWN, { pitch_number: 1800, slide: 0x23 }], { pitch_number: 1800, slide_up: { every: 2, shift: 3 } }],
    [[36, 10, 74, OWN, { slide: 0x1A, vibrato: 3, carries: true }], { key: 74, slide_down: { every: 1, shift: 2 }, vibrato: :none }],
    [[48, 10, 76, 4, { fade: 0x0A, duty: 0x88 }], { key: 76, volume: 4, swell: 2, duty: %i[eighth half eighth half] }],
    [[60, 0, 77, OWN, { pitch_number: 3000, fade: 20, slide: 0x05 }], { key: 77 }],
    [[72, 12, 79, OWN, { vibrato: 0x30, shade: -32 }], { key: 79, vibrato: :none, pan: Rational(-1, 2) }]
  ].freeze
  VOICED_LOW = [
    [[0, 20, 48, OWN, { shade: 40 }], { key: 48, pan: Rational(40, 64) }],
    [[24, 20, 50, OWN, { shade: -64 }], { key: 50, pan: -1 }],
    [[48, 20, 52, OWN, { slide: 0x23 }], { key: 52 }],
    [[72, 0, 53, OWN, { duty: 0xFF, shade: 100 }], { key: 53, duty: %i[three_quarter] * 4 }]
  ].freeze
  VOICED_WAVE = [
    [[0, 30, 0, OWN, { pitch_number: 1500, vibrato: 2 }], { pitch_number: 1500, vibrato: { depth: 2, speed: 1, after: 0 } }],
    [[36, 30, 60, 8, { fade: 3, duty: 0x55, shade: 20 }], { key: 60, volume: 8, pan: Rational(20, 64) }],
    [[72, 0, 0, OWN, { pitch_number: 1700 }], { pitch_number: 1700 }]
  ].freeze
  VOICED_DRUM = [
    [[0, 6, 60, OWN, { fade: 9 }], { key: 60, swell: 1 }],
    [[12, 6, 64, OWN, { fade: 2, shade: 64 }], { key: 64, decay: 2, pan: 1 }],
    [[24, 6, 64, OWN, { pitch_number: 1000, vibrato: 2 }], { key: 64 }],
    [[36, 6, PackNote::REST, OWN, { fade: 2 }], {}]
  ].freeze

  # A part's voiced records as a slot's bytes, ended, with filler after that no part may play.
  private def voiced_records(notes)
    tuples = notes.map { |(at, length, key, volume, settings), _| [at, length, key, OWN, volume, nil, nil, nil, settings] }
    filler = [5, 7, 64, OWN, 15, nil, 1, nil, { pitch_number: 1000, fade: 4 }]
    ending = [[PackNote::END_OF_PART, 0, 0, 0, 0, nil, nil, nil, {}]]
    PackNote.bytes_of([*tuples, *ending, *([filler] * (MOST - tuples.length - 1))], count: MOST, voiced: true)
  end

  # The notes written by hand beside +notes+' records.
  private def voiced_written(notes)
    notes.map { |(at, length, *), words| Note.new(at: at, length: (length unless length.zero?), **words) }
  end

  # A game of a song of those four parts, its notes read from voiced slots with the pack left out
  # (+folder+ given), or written by hand.
  private def voiced_game(parts, folder: nil)
    test = self
    b = VBlank::Builder.new(options: folder ? PACK_AT_START : VBlank::Cartridge::Options.new)
    from = folder && original_nowhere(folder)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = from && data_pack(from: from, version: "1") do |slots|
        parts.each_key.with_index { |name, place| slots.voiced_notes name, at: place * MOST * PackNote::VOICED_BYTES, count: MOST }
      end
      notes_of = ->(name) { pack ? pack[name].notes : test.voiced_notes_by_hand(parts.fetch(name)) }
      music = songs :music, [Score.new(parts: [Part.new(notes: notes_of.(:lead), duty: :quarter),
                                               Part.new(notes: notes_of.(:low), volume: 10),
                                               Part.new(notes: notes_of.(:wave), plays: :wave),
                                               Part.new(notes: notes_of.(:drum), plays: :noise)],
                                       tempo: 150, length: 96, loop_from: 30)]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  # Called back from the game's block, so it is public.
  def voiced_notes_by_hand(notes) = voiced_written(notes)

  def test_notes_with_their_voices_settings_read_as_the_game_starts_play_as_written_by_hand
    parts = { lead: VOICED_LEAD, low: VOICED_LOW, wave: VOICED_WAVE, drum: VOICED_DRUM }
    Dir.mktmpdir do |folder|
      by_hand = voiced_game(parts)
      left_out = voiced_game(parts, folder: folder)
      file = VBlank::Original::Pack.holding(parts.transform_values { |notes| voiced_records(notes) },
                                            sha1: Digest::SHA1.hexdigest("made up"), build_version: "1").to_bytes
      once = ->(frame) { frame == 1 ? [:a] : [] }
      wanted = game_player.input_each_frame(&once).run(by_hand, frames: 150)
      played = game_player.hand_file(file).input_each_frame(&once).run(left_out, frames: 150)

      refute_empty wanted.audio.select { |entry| entry.first == :note }, "the song written by hand plays notes"
      assert_equal wanted.audio, played.audio
      assert_equal wanted.mixed_sound, played.mixed_sound
    end
  end

  # A DRUM THAT RATTLES ON SOME HITS AND A WAVE PART THAT CHANGES WAVE, read as the game starts from
  # voiced records (Original::PackNote's bytes 25 and 26). A record's wave is one of the part's
  # (`notes(waves: [...])`): a wave of the pack, a shape, the pack's other wave; one past those, and a
  # rattle byte past 1, are the part's own. The pad holds a note across the loop in the copy's wave.
  RATTLING = [
    [[0, 6, 60, OWN, { metallic: 1 }], { key: 60, metallic: true }],
    [[8, 6, 62, OWN, { metallic: 0 }], { key: 62, metallic: false }],
    [[16, 6, 64, OWN, {}], { key: 64 }],
    [[24, 6, 60, OWN, { metallic: 7 }], { key: 60 }],
    [[32, 6, 60, OWN, { metallic: 1 }], { key: 60, metallic: true }]
  ].freeze
  WAVE_TURNS = [
    [[0, 6, 57, OWN, { wave: 0 }], { key: 57, wave: :wave_0 }],
    [[8, 6, 59, OWN, { wave: 1 }], { key: 59, wave: :sine }],
    [[16, 6, 60, OWN, { wave: 9 }], { key: 60 }],
    [[24, 0, 62, OWN, { wave: 2 }], { key: 62, wave: :wave_1 }]
  ].freeze
  # The pack's waves a note written by hand names, by which of WAVES each is.
  PACK_WAVE_NAMES = { wave_0: 0, wave_1: 1 }.freeze

  # A game of a song of the drum and the pad, read from voiced slots with the pack left out
  # (+folder+ given), or written by hand.
  private def rattling_game(folder: nil)
    test = self
    b = VBlank::Builder.new(options: folder ? PACK_AT_START : VBlank::Cartridge::Options.new)
    from = folder && original_nowhere(folder)
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = from && data_pack(from: from, version: "1") do |slots|
        slots.voiced_notes :drum, at: 0, count: MOST
        slots.voiced_notes :pad, at: MOST * PackNote::VOICED_BYTES, count: MOST
        slots.numbers :waves, at: WAVES_AT, count: WAVES.flatten.length, width: :byte, signed: false
      end
      drum = pack ? pack[:drum].notes : test.rattling_notes_by_hand(RATTLING)
      pad = pack ? pack[:pad].notes(waves: [pack[:waves].wave(0), :sine, pack[:waves].wave(1)]) : test.rattling_notes_by_hand(WAVE_TURNS)
      music = songs :music, [Score.new(parts: [Part.new(notes: drum, plays: :noise), Part.new(notes: pad, plays: :sawtooth)],
                                       tempo: 150, length: 44, loop_from: 20)]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  # Called back from the game's block, so it is public.
  def rattling_notes_by_hand(notes)
    voiced_written(notes).map { |note| PACK_WAVE_NAMES.key?(note.wave) ? note.with(wave: wave_steps(PACK_WAVE_NAMES.fetch(note.wave))) : note }
  end

  def test_a_drum_that_rattles_and_a_wave_part_that_changes_wave_read_as_the_game_starts_play_as_written_by_hand
    Dir.mktmpdir do |folder|
      by_hand = rattling_game
      left_out = rattling_game(folder: folder)
      file = VBlank::Original::Pack.holding({ drum: voiced_records(RATTLING), pad: voiced_records(WAVE_TURNS),
                                              waves: WAVES.flatten.pack("C*") },
                                            sha1: Digest::SHA1.hexdigest("made up"), build_version: "1").to_bytes
      once = ->(frame) { frame == 1 ? [:a] : [] }
      wanted = game_player.input_each_frame(&once).run(by_hand, frames: 100)
      played = game_player.hand_file(file).input_each_frame(&once).run(left_out, frames: 100)

      assert(wanted.audio.any? { |kind, wave| kind == :wave && wave && wave[:shape] == wave_steps(1) }, "the pad plays the copy's wave")
      assert(wanted.audio.any? { |kind, hit| kind == :noise && hit && hit[:metallic] }, "the drum rattles")
      assert_equal wanted.audio, played.audio
    end
  end

  # PITCHES BETWEEN KEYS THAT GLIDE, read as the game starts: a recorded part whose voiced records
  # name hz in 16ths and glides, the first shaded between the speakers, one naming an instrument and a volume as it glides (the part's
  # own, from the file), one out of range (its key), and a noise part whose hits name hz, one
  # beside a noise clock (the clock). The horn's rate is read from the file too.
  GLIDING = [
    [[0, 0, 60, OWN, { hz: 4186, shade: -44 }], { hz: Rational(4186, 16), pan: -0.6875 }],
    [[4, 0, 60, OWN, { hz: 4410, glides: true }], { hz: Rational(4410, 16), glides: true }],
    [[8, 0, 60, 7, { hz: 4700, glides: true }], { hz: Rational(4700, 16), glides: true }],
    [[14, 0, 0, 9, { hz: 3333 }], { hz: Rational(3333, 16), volume: 9 }],
    [[20, 10, 64, OWN, { hz: 0 }], { key: 64 }],
    [[34, 0, 62, OWN, { hz: 5000, glides: true }], { hz: Rational(5000, 16), glides: true }]
  ].freeze
  HISSED = [
    [[0, 6, 60, OWN, { hz: 120_000 * 16 }], { hz: 120_000 }],
    [[10, 6, 60, OWN, { hz: 7777 }], { hz: Rational(7777, 16) }],
    [[20, 6, 60, OWN, { hz: 7777 }, 0x21], { noise_clock: [1, 2] }]
  ].freeze
  HORN_RATE_AT = 2080

  # +notes+ (GLIDING or HISSED) for this run's console: a console whose recorded notes cannot
  # glide (Console::Description#glides_recordings) strikes each instead, in the records and by hand.
  private def for_console(notes)
    return notes if VBlank::Console.described(game_console).glides_recordings

    notes.map do |(record, words)|
      # A note that named an instrument and a volume as it glided strikes with them.
      struck = record[4][:glides] && record[3] != OWN ? { volume: record[3], instrument: :bell } : {}
      [[*record.first(4), record[4].except(:glides), *record.drop(5)], words.except(:glides).merge(struck)]
    end
  end

  private def gliding_records(notes)
    tuples = notes.map do |(at, length, key, volume, settings, clock), _|
      kept = VBlank::Console.described(game_console).glides_recordings ? settings : settings.except(:glides)
      [at, length, key, (settings[:glides] && volume != OWN ? 0 : OWN), volume, nil, nil, clock, kept]
    end
    ending = [[PackNote::END_OF_PART, 0, 0, 0, 0, nil, nil, nil, {}]]
    PackNote.bytes_of([*tuples, *ending], count: MOST, voiced: true)
  end

  # A game of a sound effect of those two parts, read from voiced slots with the pack left out
  # (+folder+ given), or written by hand, played on A.
  private def gliding_game(folder: nil)
    test = self
    b = VBlank::Builder.new(options: folder ? PACK_AT_START : VBlank::Cartridge::Options.new)
    from = folder && original_nowhere(folder)
    b.instance_eval do
      screen :bitmap
      enable_sound mix_rate: 13_379
      pack = from && data_pack(from: from, version: "1") do |slots|
        slots.voiced_notes :glide, at: 0, count: MOST
        slots.voiced_notes :hiss, at: MOST * PackNote::VOICED_BYTES, count: MOST
        slots.numbers :horn_rate, at: HORN_RATE_AT, count: 1, width: :half, signed: false
      end
      instrument :horn, pcm: PCM, note: :C4, rate: pack ? pack[:horn_rate].number(0) : 9000
      instrument :bell, pcm: PCM.rotate(9), rate: 8000, note: :C5
      notes_of = ->(name) { pack ? pack[name].notes(instruments: %i[bell]) : test.gliding_notes_by_hand(name) }
      effects = sound_effects :sfx, [Score.new(parts: [Part.new(plays: :horn, notes: notes_of.(:glide), volume: 13),
                                                       Part.new(plays: :noise, notes: notes_of.(:hiss))],
                                               tempo: 150, length: 48)]
      game_loop do
        wait_vblank
        effects.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  GLIDING_PARTS = { glide: GLIDING, hiss: HISSED }.freeze

  # Called back from the game's block, so it is public.
  def gliding_notes_by_hand(name) = voiced_written(for_console(GLIDING_PARTS.fetch(name)))

  def test_pitches_between_keys_that_glide_read_as_the_game_starts_play_as_written_by_hand
    Dir.mktmpdir do |folder|
      # The Color, which has no instruments, refuses the effect.
      unless VBlank::Console.for(game_console).answers.answer(:instrument).works?
        left_out = gliding_game(folder: folder)
        next assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(left_out, frames: 1) }
      end

      by_hand = gliding_game
      left_out = gliding_game(folder: folder)
      file = VBlank::Original::Pack.holding({ glide: gliding_records(GLIDING), hiss: gliding_records(HISSED),
                                              horn_rate: [9000].pack("v") },
                                            sha1: Digest::SHA1.hexdigest("made up"), build_version: "1").to_bytes
      once = ->(frame) { frame == 1 ? [:a] : [] }
      wanted = game_player.input_each_frame(&once).run(by_hand, frames: 60)
      played = game_player.hand_file(file).input_each_frame(&once).run(left_out, frames: 60)

      refute_empty wanted.audio.select { |entry| entry.first == :note }, "the effect written by hand plays notes"
      assert_equal wanted.audio, played.audio
      assert_equal wanted.mixed_sound, played.mixed_sound
    end
  end

  # Shareable, as a test class's own constants are made (test_helper.rb), since a test may run in
  # a Ractor and these are a module's.
  constants.each { |name| Ractor.make_shareable(const_get(name)) }

  # A game that declares a song and never plays one is built without the music player (the music
  # runtime feature), which is what makes a part's notes from the file. It starts all the same.
  def test_a_game_that_declares_a_song_and_plays_none_still_starts
    Dir.mktmpdir do |folder|
      silent = scored_game({ melody: MELODY }, folder: folder, plays: false) do |notes_of|
        { songs: [Score.new(parts: [Part.new(notes: notes_of.(:melody))], tempo: 150, length: 96, plays_once: true)] }
      end
      played = game_player.hand_file(pack_file({ melody: MELODY })).hold(:a).run(silent, frames: 4)

      assert_empty played.audio.select { |entry| entry.first == :note }
    end
  end

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
