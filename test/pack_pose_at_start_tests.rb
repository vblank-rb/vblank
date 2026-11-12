# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_poses"
require "pack_at_start_tests"

# A POSE FROM THE PACK, ITS PACK LEFT OUT: what the games of PackPoseGames
# (test/all/vblank/builder/test_pack_poses.rb) built with `pack_at_start: true` refuse, what a
# player's file that asks for more than the build holds draws, and what the build holds when
# written out. That each plays as its all-in-one build is the registry's (PackGames::Poses and
# PackGames::PosesOfWords, test/pack_games.rb).
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackPoseAtStartTests
  include PackPoseGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The slot's size is the game's own word, so a frame that starts past it is refused as the game
  # is built, whichever way it is built.
  def test_a_frame_past_the_end_of_its_slot_is_refused_with_the_pack_left_out
    uncounted = FRAME.with(counted: false)
    Dir.mktmpdir do |folder|
      past = assert_raises(ArgumentError) { pose_game(original(folder), frame_at: FRAME_BYTES.length, size: REACH, options: LEFT_OUT) }
      long = assert_raises(ArgumentError) do
        pose_game(original(folder), frame_at: 2, layout: uncounted, count: PIECES.length + 1, size: REACH, options: LEFT_OUT)
      end

      assert_includes past.message, "ends past the slot"
      assert_includes long.message, "ends past the slot"
    end
  end

  # WHAT THE PLAYER'S FILE HOLDS IS NOT KNOWN AS THE GAME IS BUILT, so nothing in it stops the
  # game. Here the file's frame says it has six pieces: the first two as the original's, one whose
  # tiles are past the slot, one that sits wholly outside the picture, and two more that the slot
  # ends before. The game shows the first two, as an all-in-one build of a frame of those two does.
  #
  # The file is the one the pack's unpacking makes of such a copy: the frame's record, written
  # after the slots (Original::FrameRecord::Section), holds the four pieces that end inside the
  # slot, and the game paints of them what its picture and its tiles have.
  def test_a_frame_of_the_file_that_asks_for_more_than_the_build_holds_draws_what_fits
    wild = [0xFF, 6, *PIECES.first(2).flatten, *PIECE.(-8, 0, 40, big: true), *PIECE.(60, 0, 1)]
    held = [0xFF, 2, *PIECES.first(2).flatten]
    Dir.mktmpdir do |folder|
      whole, = pose_game_and_file(original(folder, frame_bytes: held), size: REACH, frames_count: wild.length)
      from = original(folder, frame_bytes: wild)
      left_out, = pose_game_and_file(from, size: REACH, frames_count: wild.length, options: LEFT_OUT)
      slots = { sprites: VIDEO.map(&MadeUpOriginalLayouts::FOUR_PLANES).join, frames: wild.pack("C*"),
                palette: MadeUpOriginalLayouts::PALETTE.pack("v*") }
      sha1 = Digest::SHA1.hexdigest(File.binread(File.join(folder, "made_up.bin")))
      slot = VBlank::Original::Slot.numbers(:frames, at: FRAMES_AT, count: wild.length, width: :byte, signed: false, layout: :snes)
      frame = VBlank::Original::FrameRecord::Source.new(slot: slot, at: 1, count: nil, layout: FRAME)
      records = VBlank::Original::FrameRecord::Section.new(sources: [frame]).bytes(slots)
      file = VBlank::Original::Pack.holding(slots, sha1: sha1, build_version: "1", frame_records: records).to_bytes

      assert_equal game_player.run(whole, frames: 2).screen.to_a, game_player.hand_file(file).run(left_out, frames: 2).screen.to_a
    end
  end

  # The game as the block writes it out (as C, JavaScript or Ruby) holds the pose's pixels in its
  # colours when built all-in-one, so the search can find them, and none of them built with its
  # pack left out; nor a tile's bytes as the original keeps them. A lowering's test file calls this.
  private def assert_pose_written_without_the_originals_bytes(&write)
    # A row of the big piece: tile 2's row beside tile 3's, none of it see-through.
    row = (PLACES[2].first(8) + PLACES[3].first(8)).map { |place| COLORS.fetch(place) }
    Dir.mktmpdir do |folder|
      from = original(folder)
      whole, = pose_game_and_file(from, size: REACH)
      left_out, = pose_game_and_file(from, size: REACH, options: LEFT_OUT)
      ways_holding_needles([["the pose", whole, left_out, [row]]], &write)
      raw = MadeUpOriginalLayouts::FOUR_PLANES.(PLACES[1]).bytes

      assert_empty ways_holding(number_runs_in(yield(left_out)), raw), "the pose built with its pack left out holds a tile's bytes"
    end
  end
end
