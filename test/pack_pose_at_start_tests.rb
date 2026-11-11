# frozen_string_literal: true

require "digest"
require "tmpdir"
require "all/vblank/builder/test_pack_poses"
require "all/vblank/builder/test_pack_poses_of_words"
require "pack_at_start_tests"

# A POSE FROM THE PACK, ITS PACK LEFT OUT: the games of PackPoseGames
# (test/all/vblank/builder/test_pack_poses.rb) built with `pack_at_start: true` and handed the pack
# file the all-in-one build made show what the all-in-one build shows. The answer key is the
# all-in-one build on the interpreter.
#
# Only a build for a computer leaves its pack out, so these are played by the interpreter and the
# game as C, JavaScript and Ruby, and are not in test/all/ (PackAtStartTests says more).
module PackPoseAtStartTests
  include PackPoseGames
  include WrittenOutSearch

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The game built both ways, as +shape+ says, shows one picture after each of +frames+.
  private def assert_pose_plays_alike(what, frames: [1, 3], size: REACH, **shape, &more)
    Dir.mktmpdir do |folder|
      from = original(folder)
      whole, file = pose_game_and_file(from, size: size, **shape, &more)
      left_out, = pose_game_and_file(from, size: size, options: LEFT_OUT, **shape, &more)

      frames.each do |count|
        shown = game_player.run(whole, frames: count).screen.to_a
        assert_operator shown.flatten.uniq.length, :>, 2, "#{what}: the all-in-one build draws the pose"
        assert_equal shown, game_player.hand_file(file).run(left_out, frames: count).screen.to_a,
                     "#{what}: after #{count} frames the game handed its pack shows what the all-in-one build shows"
      end
    end
  end

  def test_a_pose_read_at_start_shows_as_the_all_in_one_build
    assert_pose_plays_alike("the frame")
  end

  def test_a_pose_of_a_larger_size_read_at_start_shows_as_the_all_in_one_build
    assert_pose_plays_alike("a larger size", size: [32, 40])
  end

  def test_a_frame_of_a_given_count_read_at_start_shows_as_the_all_in_one_build
    assert_pose_plays_alike("a count the game gives", frame_at: 2, layout: FRAME.with(counted: false), count: PIECES.length)
  end

  def test_a_pose_drawn_with_another_list_read_at_start_shows_as_the_all_in_one_build
    other = MadeUpOriginalLayouts::PALETTE.last(4)

    assert_pose_plays_alike("drawn with another list") do |hero|
      colors :other, [:transparent, *other.drop(1)]
      hero.draw_with :other
    end
  end

  # Turned, the pose turns about the size the game gives, in both builds.
  def test_a_pose_turned_round_read_at_start_shows_as_the_all_in_one_build
    assert_pose_plays_alike("turned round", size: [32, 24], turned: :mirror)
  end

  def test_a_pose_turned_upside_down_read_at_start_shows_as_the_all_in_one_build
    assert_pose_plays_alike("turned upside down", size: [16, 40], turned: :upside_down)
  end

  # A bank of a slot of colours for the pose's `colors:`, read from the file with its pieces.
  def test_a_pose_in_colors_from_the_pack_read_at_start_shows_as_the_all_in_one_build
    assert_pose_plays_alike("colours from the pack", pose_colors: ->(pack) { pack[:palette].bank(1, size: 4) })
  end

  def test_a_pose_with_no_size_is_refused_with_the_pack_left_out
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) { pose_game(original(folder), options: LEFT_OUT) }

      assert_includes error.message, "size:"
    end
  end

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
      file = VBlank::Original::Pack.holding(slots, sha1: sha1, build_version: "1").to_bytes

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

# A POSE WHOSE FRAME IS THE CONSOLE'S OWN SPRITE ENTRIES, ITS PACK LEFT OUT: the games of
# PackPoseOfWordsGames (test/all/vblank/builder/test_pack_poses_of_words.rb), whose frame has parts
# of two bytes and pieces of several tiles each way, built both ways as PackPoseAtStartTests'.
module PackPoseOfWordsAtStartTests
  include PackPoseOfWordsGames

  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  private def assert_pose_of_words_plays_alike(what, layout: FRAME, high_byte_first: true)
    Dir.mktmpdir do |folder|
      from = original(folder, high_byte_first: high_byte_first)
      whole, file = pose_from_pack_and_file(from, layout: layout, size: REACH)
      left_out, = pose_from_pack_and_file(from, layout: layout, size: REACH, options: LEFT_OUT)
      shown = game_player.run(whole, frames: 3).screen.to_a

      assert_operator shown.flatten.uniq.length, :>, 2, "#{what}: the all-in-one build draws the pose"
      assert_equal shown, game_player.hand_file(file).run(left_out, frames: 3).screen.to_a,
                   "#{what}: the game handed its pack shows what the all-in-one build shows"
    end
  end

  def test_a_frame_of_words_read_at_start_shows_as_the_all_in_one_build
    assert_pose_of_words_plays_alike("pieces of mixed sizes")
  end

  def test_a_layout_of_tiles_across_rows_read_at_start_shows_as_the_all_in_one_build
    assert_pose_of_words_plays_alike("tiles across rows", layout: FRAME.with(tile_order: :across_rows))
  end

  def test_a_layout_of_low_bytes_first_read_at_start_shows_as_the_all_in_one_build
    assert_pose_of_words_plays_alike("low bytes first", layout: FRAME.with(high_byte_first: false), high_byte_first: false)
  end
end
