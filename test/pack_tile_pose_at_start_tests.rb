# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_tile_poses"

# A POSE OF SPRITE TILES WHOSE PIECES ARE ONE OF THE ORIGINAL'S FRAMES, ITS PACK LEFT OUT: what the
# games of PackTilePoseGames (test/all/vblank/builder/test_pack_tile_poses.rb) built with
# `pack_at_start: true` refuse, and what a player's file whose frame the set cannot draw draws.
# That each plays as its all-in-one build is the registry's (PackGames::TilePosesOfFrames,
# test/pack_games.rb).
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackTilePoseAtStartTests
  include PackTilePoseGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The build cannot see how far the frame's pieces reach, so the pose needs size:.
  def test_a_tile_pose_of_a_frame_without_a_size_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        ball_game_builder(original(folder), options: LEFT_OUT) { |pack, at| PackTilePoseGames.frame_pose(pack, at) }
      end

      assert_includes error.message, "size:"
    end
  end

  # WHAT THE PLAYER'S FILE HOLDS IS NOT KNOWN AS THE GAME IS BUILT, so nothing in it stops the game.
  # The file's frame has a piece the set can draw, then one naming tiles past the set, one turned
  # and one off the picture's grid, which the build that holds the pack refuses. The game shows the
  # first piece alone, as an all-in-one build of a frame of that piece does.
  def test_a_frame_of_the_file_the_set_cannot_draw_all_of_draws_what_the_set_holds
    good = PIECE.(-8, -16, 0x40)
    wild = [[good, PIECE.(0, -16, 0x44), PIECE.(0, -16, 0x42, mirrored: true), PIECE.(-4, -16, 0x42)]]
    held = [[good]]
    Dir.mktmpdir do |folder|
      whole = ball_game_builder(original(folder, frames: held), frames: held).program
      left_out = ball_game_builder(original(folder, frames: wild), frames: wild, options: LEFT_OUT).program

      assert_equal game_player.run(whole, frames: 3).screen.to_a, game_player.hand_file(file_of(wild)).run(left_out, frames: 3).screen.to_a
    end
  end

  # A CROWDED ROW OF POSES READ AS THE GAME STARTS. Six balls stand side by side, each a pose twice
  # as wide as its frame's pieces reach, so the build holds a stand-in piece for every place of its
  # grid and the frame fills only half of them. On a console that draws only so many sprite pieces
  # on a line, the frame's pieces decide which are left out, as they do all-in-one.
  def test_a_crowded_row_of_poses_read_at_start_leaves_out_what_all_in_one_does
    assert_crowded_row_alike(VBlank::Cartridge::Options.new)
  end

  # The same where the Color is told to draw 8x16, so a tile and the next one under it are one piece.
  def test_a_crowded_row_of_poses_read_at_start_in_tall_pieces_leaves_out_what_all_in_one_does
    assert_crowded_row_alike(VBlank::Cartridge::Options.new(sprite_piece_size: { gbc: [8, 16] }))
  end

  private def assert_crowded_row_alike(options)
    frames = [SPIN.first]
    pose = ->(pack, at) { PackTilePoseGames.frame_pose(pack, at, size: [32, 16]) }
    left_out_options = options.with(for_computer: true, pack_at_start: true)
    Dir.mktmpdir do |folder|
      whole = ball_game_builder(original(folder, frames: frames), frames: frames, balls: 6, options: options, &pose).program
      left_out = ball_game_builder(original(folder, frames: frames), frames: frames, balls: 6, options: left_out_options, &pose).program

      assert_equal game_player.run(whole, frames: 3).screen.to_a, game_player.hand_file(file_of(frames)).run(left_out, frames: 3).screen.to_a
    end
  end

  # The pack file a player's copy holding +frames+ makes, its frames' records written.
  private def file_of(frames)
    bytes = PackTilePoseGames.frame_bytes(frames).pack("C*")
    slot = VBlank::Original::Slot.numbers(:frames, at: 0, count: bytes.bytesize, width: :byte, signed: false, layout: :gbc)
    frame = VBlank::Original::FrameRecord::Source.new(slot: slot, at: 0, count: nil, layout: TALL)
    records = VBlank::Original::FrameRecord::Section.new(sources: [frame]).bytes({ frames: bytes })
    VBlank::Original::Pack.holding({ frames: bytes }, sha1: Digest::SHA1.hexdigest(bytes), build_version: "1",
                                                     frame_records: records).to_bytes
  end
end
