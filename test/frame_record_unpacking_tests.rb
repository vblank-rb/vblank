# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_poses"
require "all/vblank/builder/test_pack_poses_of_words"
require "pack_pose_read_by_the_game_games"

# THE FRAMES A GAME NAMES, WRITTEN BY ITS PACK'S UNPACKING AS RECORDS OF VBLANK'S OWN
# (Original::FrameRewrite, Original::FrameRecord). An unpacking is game code, so the run's player
# plays it; the answer key is the pack file the all-in-one build made, whose records the build
# worked out in Ruby from the same layouts (Original::FrameRecord::Section#bytes). The two must be
# the same file, byte for byte, for every way a layout keeps a frame.
#
# The made-up original keeps the frames of test_pack_poses.rb (five bytes a piece, a row byte, a
# big bit) and of test_pack_poses_of_words.rb (the console's own sprite entries, words, a size
# byte), the second both high byte first and low byte first. The game reads them every way those
# tests do: counted and with a count the game gives, tiles down columns and across rows.
#
# Only a build for a computer plays an unpacking, so these are not in test/all/.
module FrameRecordUnpackingTests
  include SharedConstants

  BYTES = PackPoseGames
  WORDS = PackPoseOfWordsGames
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The frame of words as its bytes, in one byte order (PackPoseOfWordsGames#frame_bytes).
  WORD_FRAME = lambda do |high_byte_first|
    word, signed = high_byte_first ? ["n", "s>"] : ["v", "s<"]
    records = WORDS::PIECES.map do |piece|
      tile_word = piece.tile | (piece.mirrored ? 0x0800 : 0) | (piece.upside_down ? 0x1000 : 0) | 0xE000
      [piece.y, ((piece.columns - 1) << 2) | (piece.rows - 1), 0x5A, tile_word, piece.x].pack("#{signed}CC#{word}#{signed}")
    end
    [WORDS::PIECES.length].pack(word) + records.join
  end
  HIGH_FIRST = WORD_FRAME.(true).freeze
  LOW_FIRST = WORD_FRAME.(false).freeze
  SMALL = BYTES::FRAME_BYTES.pack("C*").freeze

  SMALL_AT = 0x20
  HIGH_FIRST_AT = 0x40
  LOW_FIRST_AT = 0x80
  TILES_AT = 0x100
  TILES = WORDS::VIDEO.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join.freeze
  COPY = begin
    copy = "\0".b * (TILES_AT + TILES.bytesize)
    copy[SMALL_AT, SMALL.bytesize] = SMALL
    copy[HIGH_FIRST_AT, HIGH_FIRST.bytesize] = HIGH_FIRST
    copy[LOW_FIRST_AT, LOW_FIRST.bytesize] = LOW_FIRST
    copy[TILES_AT, TILES.bytesize] = TILES
    copy.freeze
  end
  SHA1 = Digest::SHA1.hexdigest(COPY).freeze
  SIZE = [64, 64].freeze

  # Must be InRactors.share_constants, not Ractor.make_shareable alone: tests in several Ractors
  # write COPY to a file at once (InRactors.shareable says what that does to a plain frozen String).
  VBlank::Testing::InRactors.share_constants(self)

  private def frames_original(folder)
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, COPY)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY.bytesize } })
  end

  # The builder of a game with a pose for each way of keeping a frame, its program made. Where
  # +by_routine+, the slot of low-byte-first frames has no place in the copy and the game's
  # unpacking routine fills it; every other slot is copied as it is.
  private def frames_builder(folder, options: VBlank::Cartridge::Options.new, by_routine: false)
    from = frames_original(folder)
    b = Builder.new(options: options)
    b.instance_eval do
      screen :tiled
      colors :hero, [:transparent, *WORDS::COLORS.drop(1)]
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :sprites, at: TILES_AT, count: WORDS::TILE_COUNT
        slots.numbers :small, at: SMALL_AT, count: SMALL.bytesize, width: :byte, signed: false
        slots.numbers :high_first, at: HIGH_FIRST_AT, count: HIGH_FIRST.bytesize, width: :byte, signed: false
        slots.numbers :low_first, at: (LOW_FIRST_AT unless by_routine), count: LOW_FIRST.bytesize, width: :byte, signed: false
        if by_routine
          slots.fill_from_copy { |copy, filled| copy.copy_bytes at: LOW_FIRST_AT, count: LOW_FIRST.bytesize, into: filled[:low_first] }
        end
      end
      frames = {
        counted: pack[:small].frame(1, layout: BYTES::FRAME),
        given: pack[:small].frame(2, layout: BYTES::FRAME.with(counted: false), count: BYTES::PIECES.length),
        fewer: pack[:small].frame(2, layout: BYTES::FRAME.with(counted: false), count: 2),
        down_columns: pack[:high_first].frame(0, layout: WORDS::FRAME),
        across_rows: pack[:high_first].frame(0, layout: WORDS::FRAME.with(tile_order: :across_rows)),
        low_first: pack[:low_first].frame(0, layout: WORDS::FRAME.with(high_byte_first: false)),
        again: pack[:small].frame(1, layout: BYTES::FRAME)
      }
      frames.each do |name, frame|
        image name, tiles: pack[:sprites], frame: frame, origin: [24, 24], colors: :hero, size: SIZE
      end
      # Two of the poses are shown, one above the other: a Game Boy Color draws ten pieces of
      # sprites on a line, and one of these pictures is eight across.
      sprite :counted, at: [0, 0]
      sprite :across_rows, at: [72, 72]
      game_loop { wait_vblank }
    end
    b.finalize_program
    b
  end

  private def assert_unpacking_writes_the_builds_pack(by_routine:)
    Dir.mktmpdir do |folder|
      whole = frames_builder(folder, by_routine: by_routine)
      left_out = frames_builder(folder, options: LEFT_OUT, by_routine: by_routine)
      release = VBlank::Original::Release.from("Test", { "sha1" => SHA1, "size" => COPY.bytesize })
      unpacking = left_out.declared_data_pack.unpacking(release: release)
      played = game_player.hand_file(COPY).run(unpacking.program, frames: 40)
      unpacked = unpacking.pack_file_in(played, sha1: SHA1, build_version: "1")

      assert unpacking.finished_in?(played), "the unpacking got to its end"
      assert_nil unpacking.fault_in(played)
      assert_equal whole.made_data_pack_file.unpack1("H*"), unpacked.unpack1("H*")
      # Six frames are named, one of them twice, and each has a record with pieces in it.
      records = VBlank::Original::Pack.from_bytes(unpacked).frame_records
      assert_equal 6, unpacking.frames.sources.length
      held = Array.new(6) do |frame|
        VBlank::Original::FrameRecord.read_entry(records, entry_at: frame * VBlank::Original::FrameRecord::ENTRY_BYTES, section_at: 0)
      end
      assert_equal [3, 3, 2, 5, 5, 5], held.map { |frame| frame.pieces.length }
      shown = game_player.run(whole.program, frames: 3).screen.to_a
      assert_operator shown.flatten.uniq.length, :>, 2, "the all-in-one build draws the poses"
      assert_equal shown, game_player.hand_file(unpacked).run(left_out.program, frames: 3).screen.to_a
    end
  end

  def test_the_unpacking_writes_each_frames_record_as_the_build_does
    assert_unpacking_writes_the_builds_pack(by_routine: false)
  end

  # A slot the game's own routine fills is read for its frames once the routine has run.
  def test_the_unpacking_writes_the_frames_of_a_slot_its_routine_fills
    assert_unpacking_writes_the_builds_pack(by_routine: true)
  end

  # A FRAME THE GAME READS WITH A READER OF ITS OWN (PackPoseReadByTheGameGames), given a value
  # from each pose: the reader's sums, run on the game's values, are the routine, and write the
  # records the build worked out in Ruby from the same reader. One frame given two values is two
  # records, each its own tiles.
  def test_the_unpacking_writes_the_records_of_frames_a_games_reader_reads
    Dir.mktmpdir do |folder|
      read = ReadByTheGame.new
      whole = read.builder(folder, VBlank::Cartridge::Options.new)
      left_out = read.builder(folder, LEFT_OUT)
      copy = read.copy(folder)
      sha1 = Digest::SHA1.hexdigest(copy)
      release = VBlank::Original::Release.from("Test", { "sha1" => sha1, "size" => copy.bytesize })
      unpacking = left_out.declared_data_pack.unpacking(release: release)
      # Its tiles are 10 KB, a frame of the unpacking each 256 bytes. No shell holds an unpacking to
      # a cartridge's memory, so it is played unchecked, as PackParityTests plays one.
      player = game_player.hand_file(copy)
      played = VBlank::Testing::BuildChecks.without_checks { player.run(unpacking.program, frames: 80) }
      unpacked = unpacking.pack_file_in(played, sha1: sha1, build_version: "1")

      assert unpacking.finished_in?(played), "the unpacking got to its end"
      assert_nil unpacking.fault_in(played)
      assert_equal whole.made_data_pack_file.unpack1("H*"), unpacked.unpack1("H*")
      shown = game_player.run(whole.program, frames: 3).screen.to_a
      assert_operator shown.flatten.uniq.length, :>, 2, "the all-in-one build draws the poses"
      assert_equal shown, game_player.hand_file(unpacked).run(left_out.program, frames: 3).screen.to_a
    end
  end

  # The games of PackPoseReadByTheGameGames, kept apart from this module's own made-up original.
  class ReadByTheGame
    include PackPoseReadByTheGameGames

    def builder(folder, options) = poses_read_by_the_game_builder(original(folder), options: options)
    def copy(folder) = File.binread(File.join(folder, "made_up_blocks.bin"))
  end

  # The all-in-one build's unpacking writes the records too: it is the program every backend is
  # held to, handed the copy the build read.
  def test_the_all_in_one_builds_unpacking_writes_the_records_too
    Dir.mktmpdir do |folder|
      whole = frames_builder(folder, by_routine: true)
      unpacking = whole.declared_data_pack.unpacking
      played = unpacking.run_on(game_player, frames: 40)

      assert_equal whole.made_data_pack_file.unpack1("H*"), unpacking.pack_file_in(played, sha1: SHA1, build_version: "1").unpack1("H*")
    end
  end
end
