# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# A made-up original whose frames name tiles of a run the game rewrites, and a game whose poses of
# a set of sprite tiles take their pieces from those frames. Shared by the tests below, the tests of
# the same game with its pack left out (test/pack_pose_at_start_tests.rb), the registry of pack
# games (test/pack_games.rb) and the shell check's test (test/lowering/ruby/vblank/live/test_shell_check.rb).
#
# The original keeps a frame as a Game Boy keeps its sprite table: a count, then four bytes a
# piece, y and x (signed, from the object's place), the tile, and flags (bit 5 mirrored, bit 6
# upside down). A piece is 8x16, the tile above and the next one under it. The run of tiles its
# frames name starts at tile 0x40 of sprite memory, so a frame's tile 0x42 is tile 2 of the set.
module PackTilePoseGames
  include SharedConstants

  READ_PIECE = lambda do |bytes, _pose|
    VBlank::Original::FrameLayout::Piece.new(x: bytes.signed(1), y: bytes.signed(0), tile: bytes[2], rows: 2, row_step: 1,
                                             mirrored: (bytes[3] >> 5) & 1, upside_down: (bytes[3] >> 6) & 1)
  end
  TALL = VBlank::Original::FrameLayout.new(piece_bytes: 4, counted: true, piece: READ_PIECE)

  FIRST_TILE = 0x40
  # A piece: where it sits from the object's place, its tile, and its turns.
  PIECE = ->(x, y, tile, mirrored: false) { [y & 0xFF, x & 0xFF, tile, mirrored ? 0x20 : 0] }
  # Two frames of a ball 16 pixels square about its place, which is its bottom middle: the left
  # half tiles 0 and 1, the right half tiles 2 and 3, and the second frame the halves swapped.
  SPIN = [[PIECE.(-8, -16, 0x40), PIECE.(0, -16, 0x42)], [PIECE.(-8, -16, 0x42), PIECE.(0, -16, 0x40)]].freeze
  # The same frames as pieces of the set written by hand: the answer key.
  BY_HAND = [[[0, 0, 0], [0, 8, 1], [8, 0, 2], [8, 8, 3]], [[0, 0, 2], [0, 8, 3], [8, 0, 0], [8, 8, 1]]].freeze
  ORIGIN = [8, 16].freeze
  SIZE = [16, 16].freeze

  # Four tiles of 8x8 one under the other, each different in every row, in four colours so the
  # Game Boy Color shows them too.
  KINDS = Array.new(4) { |tile| (0...64).map { |at| 1 + (((at % 8) + (at / 8) + tile) % 3) } }.flatten.freeze

  VBlank::Testing::InRactors.share_constants(self)

  # The frames, one after another: each a count and its pieces. +frames+ are lists of pieces.
  def self.frame_bytes(frames) = frames.flat_map { |pieces| [pieces.length, *pieces.flatten] }

  # Where each frame of +frames+ starts.
  def self.frame_starts(frames) = frames.each_with_object([0]) { |pieces, starts| starts << (starts.last + 1 + (pieces.length * 4)) }.first(frames.length)

  # The made-up original, which holds the frames and nothing else.
  private def original(folder, frames: SPIN) = PackTilePoseGames.original_in(folder, frames: frames)

  def self.original_in(folder, frames: SPIN)
    copy = frame_bytes(frames).pack("C*")
    path = File.join(folder, "made_up_frames.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :gbc,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # THE GAME, as a block a Builder or VBlank.game runs: a set of four tiles, a pose of it for each
  # of +frames+ (each pose's options made by +pose+ from the pack and the frame's start), a ball
  # spinning through them, and the set loaded from a picture of the game's own on the first pass.
  def self.ball_game(from, frames: SPIN, &pose)
    kinds = KINDS
    starts = frame_starts(frames)
    total = frame_bytes(frames).length
    # Held as a local, since the game's block runs after this method has returned.
    pose_options = pose
    proc do
      screen :tiled
      colors :ball, %i[transparent red green white]
      image :kinds, width: 8, height: 32, colors: :ball, places: kinds
      pack = data_pack from: from, version: "1" do |slots|
        slots.numbers :frames, at: 0, count: total, width: :byte, signed: false
      end
      set = sprite_tiles :ball_tiles, count: 4, colors: :ball
      poses = starts.each_with_index.map do |at, number|
        image :"spin#{number}", tiles_from: :ball_tiles, **pose_options.call(pack, at)
        :"spin#{number}"
      end
      poses.one? ? sprite(:ball, at: [40, 20], image: poses.first) : sprite(:ball, at: [40, 20], frames: poses, rate: 2)
      set.copy_from :kinds, at: 0, count: 4, to: 0
      game_loop { wait_vblank }
    end
  end

  # The options of a pose of the frame at +at+, as a game writes them.
  def self.frame_pose(pack, at, **more)
    { frame: pack[:frames].frame(at, layout: TALL), first_tile: FIRST_TILE, origin: ORIGIN, **more }
  end

  # The game as a Builder makes it, as +options+ say (Cartridge::Options).
  private def ball_game_builder(from, options: VBlank::Cartridge::Options.new, frames: SPIN, &pose)
    pose ||= ->(pack, at) { PackTilePoseGames.frame_pose(pack, at, size: SIZE) }
    b = Builder.new(options: options)
    b.instance_eval(&PackTilePoseGames.ball_game(from, frames: frames, &pose))
    b.finalize_program
    b
  end
end

# A POSE OF A SET OF SPRITE TILES WHOSE PIECES ARE ONE OF THE ORIGINAL'S FRAMES (Builder::SpriteTiles,
# `image ..., tiles_from:, frame:`). The answer key is the same poses with their pieces written by
# hand, which is what the made-up frames say.
class TestPackTilePoses < Minitest::Test
  include PackTilePoseGames

  # The game of +frames+ (each a list of PIECE's bytes) in place of SPIN.
  private def game_of_frames(folder, frames) = ball_game_builder(original(folder, frames: frames), frames: frames)

  private def screens(program, passes) = (1..passes).map { |pass| game_player.run(program, frames: pass).screen.to_a }

  def test_poses_of_the_frames_show_what_the_same_pieces_written_by_hand_show
    Dir.mktmpdir do |folder|
      by_hand = BY_HAND
      framed = ball_game_builder(original(folder)).program
      written = ball_game_builder(original(folder)) { |_pack, at| { pieces: by_hand.fetch(PackTilePoseGames.frame_starts(SPIN).index(at)) } }.program
      shown = screens(framed, 6)

      assert_equal screens(written, 6), shown
      refute_equal shown[3], shown[5], "the ball does not spin"
    end
  end

  # With no size: the picture is as far as the pieces reach.
  def test_a_pose_given_no_size_reaches_as_far_as_its_pieces
    Dir.mktmpdir do |folder|
      sized = ball_game_builder(original(folder)).program
      reached = ball_game_builder(original(folder)) { |pack, at| PackTilePoseGames.frame_pose(pack, at) }.program

      assert_equal screens(sized, 4), screens(reached, 4)
    end
  end

  def test_a_piece_naming_a_tile_outside_the_set_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { game_of_frames(folder, [[PIECE.(-8, -16, 0x44)]]) }

      assert_includes error.message, "sprite_tiles :ball_tiles"
      assert_includes error.message, "first_tile:"
    end
  end

  def test_a_turned_piece_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { game_of_frames(folder, [[PIECE.(-8, -16, 0x40, mirrored: true)]]) }

      assert_includes error.message, "turned"
    end
  end

  def test_a_piece_off_the_pictures_grid_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { game_of_frames(folder, [[PIECE.(-4, -16, 0x40)]]) }

      assert_includes error.message, "8-pixel grid"
    end
  end

  def test_a_frame_pose_without_first_tile_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        ball_game_builder(original(folder)) { |pack, at| PackTilePoseGames.frame_pose(pack, at).except(:first_tile) }
      end

      assert_includes error.message, "first_tile:"
    end
  end
end
