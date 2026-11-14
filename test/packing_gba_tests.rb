# frozen_string_literal: true

require "digest"
require "tmpdir"
require "made_up_original"
require "m4a_answers"

# THE GAME BOY ADVANCE BIOS'S FORMATS AS BUILDING BLOCKS OF AN UNPACKING ROUTINE
# (Original::Packing::GBA): `copy.unpack_lz77` and `copy.unpack_rle`, played where an unpacking
# routine runs (CopyReaderTests says where, and which files include this). Their answer key is
# BiosCompress, the packer the GBA lowering uses.
module PackingGBATests
  include MadeUpOriginal

  # The made-up original's routine (MadeUpOriginal#unpacked_pack), its slots read back from what it
  # wrote.
  def test_the_routine_unpacks_an_lz77_block_and_an_rle_block_into_one_pack
    Dir.mktmpdir do |folder|
      unpacking = unpacked_pack(VBlank::Builder.new, folder).unpacking
      played = unpacking.run_on(game_player, frames: 8)

      assert_equal({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") },
                   unpacking.slot_bytes_in(played))
    end
  end

  # A longer block, with runs and repeats both, packed each way and unpacked by the routine back to
  # its bytes.
  def test_each_decompressor_gives_back_what_bios_compress_packed
    raw = ((0...90).map { |at| (at * 7) & 0x3F } + [0] * 40 + (0...90).map { |at| (at * 7) & 0x3F } + [5] * 3).pack("C*")
    copy = Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize) +
           Packer.with_bios_header(Packer.rle(raw), Packer::TYPE_RLE, raw.bytesize)
    rle_at = Packer.with_bios_header(Packer.lz77(raw), Packer::TYPE_LZ77, raw.bytesize).bytesize
    Dir.mktmpdir do |folder|
      from = copy_of(folder, copy)
      unpacking = VBlank::Builder.new.data_pack(from: from, version: "1") do |slots|
        slots.numbers :by_lz77, count: raw.bytesize, width: :byte, signed: false
        slots.numbers :by_rle, count: raw.bytesize, width: :byte, signed: false
        slots.fill_from_copy do |bytes, pack|
          bytes.unpack_lz77 at: 0, into: pack[:by_lz77]
          bytes.unpack_rle at: rle_at, into: pack[:by_rle]
        end
      end.unpacking

      assert_equal({ by_lz77: raw, by_rle: raw }, unpacking.slot_bytes_in(unpacking.run_on(game_player, frames: 8)))
    end
  end

  # THE ADVANCE'S COMMON SOUND DRIVER (Packing::M4A), whose answer key is M4AAnswers: a made-up song
  # whose tracks use every command the reader reads, and one that ends, each track's notes, the
  # songs' lengths and loops, and a recording and its voice's settings. The song of every command
  # never comes round whole (its first track counts its rounds in the driver's memory), so it is
  # written for as many rounds as the reader keeps.
  M4A_NOTES = 176

  private def m4a_unpacking(folder, &fill)
    VBlank::Builder.new.data_pack(from: copy_of(folder, M4AAnswers::COPY), version: "1") do |slots|
      3.times { |track| slots.notes :"track_#{track}", count: M4A_NOTES }
      slots.notes :noise_drums, count: M4A_NOTES
      slots.notes :recorded_drums, count: M4A_NOTES
      3.times { |track| slots.notes :"ending_#{track}", count: M4A_NOTES }
      slots.numbers :length, count: 2, width: :half, signed: false
      slots.numbers :ending_length, count: 2, width: :half, signed: false
      slots.samples :wave, count: 40
      slots.numbers :wave_voice, count: 4, width: :word, signed: false
      slots.numbers :one_shot_voice, count: 4, width: :word, signed: false
      3.times { |track| slots.voiced_notes :"voiced_#{track}", count: M4A_NOTES }
      slots.numbers :wave_pattern, count: 16, width: :byte, signed: false
      slots.fill_from_copy(&fill)
    end.unpacking
  end

  private def m4a_slots(folder, frames: 60, &fill)
    unpacking = m4a_unpacking(folder, &fill)
    run = unpacking.run_on(game_player, frames: frames)
    assert unpacking.finished_in?(run), "the unpacking runs to its end"
    assert_nil unpacking.fault_in(run)
    unpacking.slot_bytes_in(run)
  end

  def test_each_track_of_a_music_player_2000_song_is_written_as_the_drivers_notes
    song = M4AAnswers::SONG_AT
    ending = M4AAnswers::ENDING_SONG_AT
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        3.times { |track| copy.unpack_m4a_track at: song, into: pack[:"track_#{track}"], track: track }
        copy.unpack_m4a_track at: song, into: pack[:noise_drums], track: 2, kind: 4
        copy.unpack_m4a_track at: song, into: pack[:recorded_drums], track: 2, kind: 0
        3.times { |track| copy.unpack_m4a_track at: ending, into: pack[:"ending_#{track}"], track: track }
      end

      3.times do |track|
        assert_equal M4AAnswers.track_bytes(song, track, count: M4A_NOTES), slots.fetch(:"track_#{track}"), "track #{track}"
      end
      assert_equal M4AAnswers.track_bytes(song, 2, count: M4A_NOTES, kind: 4), slots.fetch(:noise_drums)
      assert_equal M4AAnswers.track_bytes(song, 2, count: M4A_NOTES, kind: 0), slots.fetch(:recorded_drums)
      3.times do |track|
        assert_equal M4AAnswers.track_bytes(ending, track, count: M4A_NOTES), slots.fetch(:"ending_#{track}"), "ending track #{track}"
      end
    end
  end

  # THE CONSOLE VOICES' OWN SETTINGS: each track's notes voiced, the squares' duty, the first
  # square's slide and each square's and the noise's envelope as the driver sets the voice up,
  # and the wave voice's pattern.
  def test_each_tracks_console_voices_take_their_settings_from_the_voice_group
    song = M4AAnswers::SONG_AT
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        3.times { |track| copy.unpack_m4a_voiced_track at: song, into: pack[:"voiced_#{track}"], track: track }
        copy.unpack_m4a_voice at: M4AAnswers::GROUP_AT + (12 * 3), into: pack[:wave_pattern]
      end

      3.times do |track|
        assert_equal M4AAnswers.voiced_track_bytes(song, track, count: M4A_NOTES), slots.fetch(:"voiced_#{track}"), "track #{track}"
      end
      assert_equal M4AAnswers::WAVE_PATTERN.pack("C*"), slots.fetch(:wave_pattern)
    end
  end

  # A RECORDING'S NOTE, VOICED: where it sits between the speakers, a pitch between keys, and each
  # bend while it sounds a record that glides, as the driver moves the pitch of a sounding note.
  def test_each_recorded_note_voiced_keeps_its_side_and_its_bends
    song = M4AAnswers::BENDING_SONG_AT
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        2.times { |track| copy.unpack_m4a_voiced_track at: song, into: pack[:"voiced_#{track}"], track: track }
      end

      2.times do |track|
        assert_equal M4AAnswers.voiced_track_bytes(song, track, count: M4A_NOTES), slots.fetch(:"voiced_#{track}"), "track #{track}"
      end
      notes = VBlank::Original::PackNote.list_in(slots.fetch(:voiced_0), voiced: true)
      assert(notes.any?(&:glides), "a bend while a note sounds glides")
      assert(notes.any? { |note| note.hz && !note.glides }, "a note struck between keys names its hz")
      assert(notes.any? { |note| note.shade&.negative? }, "a note on the left names its shade")
    end
  end

  # Tracks that switch between voices of the group, a drum kit and a key split. By default each
  # number the voice-and-kit track's records name is one voice the driver played; with the kit's and
  # the split's numbers set as a port sets them (M4AAnswers::MIXED_PARTS), each note's number picks,
  # from the part's instruments, the voice the driver played (Packing::M4A, "THE INSTRUMENT BYTE").
  def test_a_track_switching_between_voices_a_kit_and_a_split_numbers_each_voice_apart
    song = M4AAnswers::MIXED_SONG_AT
    parts = M4AAnswers::MIXED_PARTS
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        copy.unpack_m4a_track at: song, into: pack[:track_0], track: 0, kind: 0
        parts.each_with_index do |part, n|
          copy.unpack_m4a_track at: song, into: pack[:"track_#{n + 1}"], track: part.track, kind: 0, **part.numbering.to_h
        end
      end

      assert_equal M4AAnswers.track_bytes(song, 0, count: M4A_NOTES, kind: 0), slots.fetch(:track_0)
      numbers = M4AAnswers.records(song, 0, kind: 0).map { |record| record[3] }
      voices = M4AAnswers.voices_played(song, 0, kind: 0)
      assert_equal voices.uniq.length, numbers.uniq.length, "by default, one number for each voice played"
      assert_equal voices.uniq.length, voices.zip(numbers).uniq.length, "by default, one voice for each number"

      named = M4AAnswers::MIXED_VOICES.invert
      parts.each_with_index do |part, n|
        assert_equal M4AAnswers.track_bytes(song, part.track, count: M4A_NOTES, kind: 0, numbering: part.numbering), slots.fetch(:"track_#{n + 1}")
        played = M4AAnswers.voices_played(song, part.track, kind: 0, numbering: part.numbering).map { |voice| named.fetch(voice) }
        numbers = M4AAnswers.records(song, part.track, kind: 0, numbering: part.numbering).map { |record| record[3] }
        assert_equal played, numbers.map { |number| part.instruments.fetch(number) }, "track #{part.track}"
      end
    end
  end

  def test_a_music_player_2000_songs_length_and_loop_are_the_frames_the_driver_plays_them_on
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        copy.unpack_m4a_length at: M4AAnswers::SONG_AT, into: pack[:length]
        copy.unpack_m4a_length at: M4AAnswers::ENDING_SONG_AT, into: pack[:ending_length]
      end

      assert_equal M4AAnswers.length(M4AAnswers::SONG_AT).pack("v2"), slots.fetch(:length)
      assert_equal M4AAnswers.length(M4AAnswers::ENDING_SONG_AT).pack("v2"), slots.fetch(:ending_length)
    end
  end

  # A SONG WHOSE TRACKS COME ROUND AT DIFFERENT POINTS (M4AAnswers::ROUNDS_TRACKS), its second
  # round a frame later in the tempo's count than its first and its first track's rounds counted
  # in the driver's memory: written until the two come round together, and its length the frames
  # to there.
  def test_a_song_whose_tracks_come_round_apart_is_written_until_they_come_round_together
    song = M4AAnswers::ROUNDS_SONG_AT
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        2.times { |track| copy.unpack_m4a_track at: song, into: pack[:"track_#{track}"], track: track }
        copy.unpack_m4a_length at: song, into: pack[:length]
      end

      2.times do |track|
        assert_equal M4AAnswers.track_bytes(song, track, count: M4A_NOTES), slots.fetch(:"track_#{track}"), "track #{track}"
      end
      assert_equal M4AAnswers.length(song).pack("v2"), slots.fetch(:length)
    end
  end

  # The same song played from the pack for four times its length, as the driver plays it on past
  # every loop: the notes the answer key's player strikes in those frames, copied into the pack as
  # they are and played once, sound the same.
  ROUNDS_FRAMES = 180

  def test_a_song_whose_tracks_come_round_apart_plays_as_the_driver_past_its_first_loop
    song = M4AAnswers::ROUNDS_SONG_AT
    played = (0...2).map { |track| M4AAnswers.played_track_bytes(song, track, frames: ROUNDS_FRAMES, count: M4A_NOTES) }
    Dir.mktmpdir do |folder|
      read = rounds_game(File.join(folder, "read"), M4AAnswers::COPY) do |copy, pack|
        2.times { |track| copy.unpack_m4a_track at: song, into: pack[:"track_#{track}"], track: track }
        copy.unpack_m4a_length at: song, into: pack[:length]
      end
      driver = rounds_game(File.join(folder, "driver"), played.join + [ROUNDS_FRAMES, 0xFFFF].pack("v2")) do |copy, pack|
        2.times { |track| copy.copy_bytes at: track * played[0].bytesize, count: played[0].bytesize, into: pack[:"track_#{track}"] }
        copy.copy_bytes at: 2 * played[0].bytesize, count: 4, into: pack[:length]
      end
      wanted = game_player.input_each_frame { |frame| frame == 1 ? [:a] : [] }.run(driver.(plays_once: true), frames: ROUNDS_FRAMES)
      heard = game_player.input_each_frame { |frame| frame == 1 ? [:a] : [] }.run(read.(plays_once: false), frames: ROUNDS_FRAMES)

      assert wanted.audio.any?, "the song sounds"
      assert_equal wanted.audio, heard.audio
    end
  end

  # A game playing the two squares' tracks of the rounds song from a pack of +bytes+ that +fill+
  # unpacks; called with `plays_once:`, it is the game, coming round at the pack's loop or not.
  private def rounds_game(folder, bytes, &fill)
    Dir.mkdir(folder)
    from = copy_of(folder, bytes)
    lambda do |plays_once:|
      b = VBlank::Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        pack = data_pack(from: from, version: "1") do |slots|
          2.times { |track| slots.notes :"track_#{track}", count: M4A_NOTES }
          slots.numbers :length, count: 2, width: :half, signed: false
          slots.fill_from_copy(&fill)
        end
        parts = Array.new(2) { |track| VBlank::Audio::Score::Part.new(notes: pack[:"track_#{track}"].notes) }
        timing = pack[:length]
        score = VBlank::Audio::Score.new(parts: parts, tempo: 3600, ticks_per_beat: 1, length: timing.number(0), longest: ROUNDS_FRAMES,
                                         **(plays_once ? { plays_once: true } : { loop_from: timing.number(1) }))
        music = songs :music, [score]
        game_loop do
          wait_vblank
          music.play 0 if pressed(:a)
        end
      end
      b.finalize_program
      b.program
    end
  end

  def test_a_music_player_2000_voices_recording_and_settings_are_its_wave_and_envelope
    group = M4AAnswers::GROUP_AT
    Dir.mktmpdir do |folder|
      slots = m4a_slots(folder) do |copy, pack|
        copy.unpack_m4a_recording at: group, into: pack[:wave]
        copy.unpack_m4a_voice at: group, into: pack[:wave_voice]
        copy.unpack_m4a_voice at: group + (12 * 7), into: pack[:one_shot_voice], mix_rate: 13_379
      end

      wave = M4AAnswers::WAVE_SAMPLES
      assert_equal M4AAnswers.recording_bytes(wave).ljust(40, "\0"), slots.fetch(:wave)
      assert_equal M4AAnswers.voice_settings_bytes(M4AAnswers::WAVE_RATE, M4AAnswers::WAVE_LOOP, wave.length, [255, 0, 255, 165]),
                   slots.fetch(:wave_voice)
      one_shot = M4AAnswers::ONE_SHOT_SAMPLES.length
      assert_equal M4AAnswers.voice_settings_bytes(13_379, M4AAnswers::NO_HOLD, one_shot, [255, 40, 200, 10]), slots.fetch(:one_shot_voice)
    end
  end

  # A game playing the made-up song's voice that does not loop as a long note of a song, its
  # samples and settings unpacked by the routine, the hold read from the pack when +from_pack+, or
  # left out.
  private def one_shot_voice_game(folder, from_pack:)
    score = VBlank::Audio::Score
    long = score.new(tempo: 150, length: 40, plays_once: true,
                     parts: [score::Part.new(plays: :voice, notes: [score::Note.new(at: 0, key: :C4, length: 30)])])
    group = M4AAnswers::GROUP_AT
    samples = M4AAnswers::ONE_SHOT_SAMPLES.length
    from = copy_of(folder, M4AAnswers::COPY)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      pack = data_pack(from: from, version: "1") do |slots|
        slots.samples :wave, count: samples
        slots.numbers :settings, count: 4, width: :word, signed: false
        slots.fill_from_copy do |copy, into|
          copy.unpack_m4a_recording at: group + (12 * 7), into: into[:wave]
          copy.unpack_m4a_voice at: group + (12 * 7), into: into[:settings], mix_rate: 13_379
        end
      end
      instrument :voice, pcm: pack[:wave], rate: pack[:settings].number(0), note: :C4,
                         holds_from: (pack[:settings].number(1) if from_pack)
      music = songs :music, [long]
      game_loop do
        wait_vblank
        music.play 0 if pressed(:a)
      end
    end
    b.finalize_program
    b.program
  end

  # The voice's recording is shorter than the note, so held it would go round; one that does not
  # loop plays once and is silent after, as the same instrument written without `holds_from:`. A
  # console with no instruments (the Color) refuses the game.
  def test_a_music_player_2000_voice_that_does_not_loop_plays_once
    Dir.mktmpdir do |folder|
      unless VBlank::Console.for(game_console).answers.answer(:instrument).works?
        return assert_raises(VBlank::IR::Guardrails::ValidationError) { game_player.run(one_shot_voice_game(folder, from_pack: true), frames: 1) }
      end

      wanted = game_player.input_each_frame { |frame| frame == 1 ? [:a] : [] }.run(one_shot_voice_game(folder, from_pack: false), frames: 30)
      heard = game_player.input_each_frame { |frame| frame == 1 ? [:a] : [] }.run(one_shot_voice_game(folder, from_pack: true), frames: 30)

      assert wanted.mixed_sound.flatten.any? { |level| level != 0 }, "the voice sounds"
      assert_equal wanted.mixed_sound, heard.mixed_sound
    end
  end
end
