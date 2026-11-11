# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_poses_of_split_tiles"

# A POSE WHOSE TILE NUMBERS ARE KEPT IN TWO PLACES, ITS PACK LEFT OUT: the game of
# PackPoseOfSplitTileGames (test/all/vblank/builder/test_pack_poses_of_split_tiles.rb) built with
# `pack_at_start: true`. The layout's `tile_high_bit:` is known to Original::FrameLayout alone:
# the pack's unpacking writes each frame as a record of VBlank's own (Original::FrameRecord), and
# that record is all the interpreter and the game as C, JavaScript and Ruby read.
#
# Only a build for a computer leaves its pack out, and only those play an unpacking, so these are
# not in test/all/.
module PackPoseOfSplitTilesAtStartTests
  include PackPoseOfSplitTileGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  def test_a_tile_whose_high_bit_is_among_the_flags_read_at_start_shows_as_the_all_in_one_build
    Dir.mktmpdir do |folder|
      from = original(folder)
      whole = builder_reading_frame(from, size: REACH)
      left_out = builder_reading_frame(from, size: REACH, options: LEFT_OUT)
      shown = game_player.run(whole.program, frames: 3).screen.to_a

      assert_operator shown.flatten.uniq.length, :>, 2, "the all-in-one build draws the pose"
      assert_equal shown, game_player.hand_file(whole.made_data_pack_file).run(left_out.program, frames: 3).screen.to_a
    end
  end

  # The slot of frames is copied as it is, with no routine of the game's, and the unpacking writes
  # the frame's record all the same: played here, it makes the file the all-in-one build made,
  # and the game left out of its pack plays from it.
  def test_the_unpacking_writes_the_pack_the_all_in_one_build_made
    Dir.mktmpdir do |folder|
      from = original(folder)
      copy = File.binread(File.join(folder, "made_up.bin"))
      sha1 = Digest::SHA1.hexdigest(copy)
      whole = builder_reading_frame(from, size: REACH)
      left_out = builder_reading_frame(from, size: REACH, options: LEFT_OUT)
      release = VBlank::Original::Release.from("Test", { "sha1" => sha1, "size" => copy.bytesize })
      unpacking = left_out.declared_data_pack.unpacking(release: release)
      played = game_player.hand_file(copy).run(unpacking.program, frames: 200)
      unpacked = unpacking.pack_file_in(played, sha1: sha1, build_version: "1")

      assert unpacking.finished_in?(played), "the unpacking got to its end"
      assert_equal whole.made_data_pack_file, unpacked
      assert_equal game_player.run(whole.program, frames: 3).screen.to_a,
                   game_player.hand_file(unpacked).run(left_out.program, frames: 3).screen.to_a
    end
  end
end
