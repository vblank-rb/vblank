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
  # songs' lengths and loops, and a recording and its voice's settings.
  M4A_NOTES = 16

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
      assert_equal M4AAnswers.voice_settings_bytes(13_379, one_shot, one_shot, [255, 40, 200, 10]), slots.fetch(:one_shot_voice)
    end
  end
end
