# frozen_string_literal: true

require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"
require "all/vblank/builder/test_pack_tile_pictures"

# WHAT A PICTURE THE BUILD DOES NOT HOLD COSTS THE WRITTEN GAME. A build that reads its pack as the
# game starts (a shell) knows a pose of the original's frames, or a background's tiles, only by its
# size: every pixel is filled from the file as the game starts. So the written game holds none of
# them, however many sprites, lists of colours, recolourings, banks or turns draw them: a bigger
# picture costs the written program a few numbers at most, never its pixels again for each way it is
# drawn. A port's title of a hundred poses, each drawn in sixty sets of colours, would otherwise be
# a page of hundreds of megabytes.
#
# Each lowering whose build is written out says how it measures it (#written_bytes): the game as
# JavaScript, which is what a web page holds of it, the game as C with the files its big tables
# are embedded from, and the game as Ruby with its runtime. Played with the games of PackPoseBankColorGames and PackTilePictureGames, which
# the registry (PackGames, test/pack_games.rb) holds alike to their all-in-one builds on every pass.
module PackStandInSizeTests
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The poses as the registry's game has them, and as big as a title's actor.
  SMALL_POSE = [16, 8].freeze
  BIG_POSE = [120, 96].freeze
  # A map, and one four times as many cells.
  FEW_CELLS = 24
  MANY_CELLS = 96

  # How many bytes a pixel is kept in at the least: sixteen bits.
  PIXEL_BYTES = 2

  # The games' builders, each in its own object, since the two modules each name a made-up original
  # of their own by one name.
  class Actors
    include PackPoseBankColorGames
  end

  class Belts
    include PackTilePictureGames
  end

  def test_poses_read_at_start_made_bigger_cost_the_written_game_less_than_one_pose_of_pixels
    small, big = [SMALL_POSE, BIG_POSE].map do |size|
      Dir.mktmpdir { |folder| written_bytes(program_played(Actors.new.recolored_actors_builder(folder, size: size, options: LEFT_OUT).program)) }
    end
    one_pose = ((BIG_POSE.inject(:*) - SMALL_POSE.inject(:*)) * PIXEL_BYTES)

    assert_operator big - small, :<, one_pose,
                    "Made #{BIG_POSE.join('x')} from #{SMALL_POSE.join('x')}, the poses read as the game starts grew the written " \
                    "game from #{small} to #{big} bytes, more than one pose's #{one_pose} bytes of pixels more"
  end

  def test_a_background_read_at_start_given_more_cells_costs_the_written_game_less_than_their_pixels
    few, many = [FEW_CELLS, MANY_CELLS].map do |cells|
      words = PackTilePictureGames.title_belt_words(cells)
      Dir.mktmpdir { |folder| written_bytes(program_played(Belts.new.title_belt_game_and_file(folder, words: words, in_other_lists: true, options: LEFT_OUT).first)) }
    end
    their_pixels = (MANY_CELLS - FEW_CELLS) * 64 * PIXEL_BYTES

    assert_operator many - few, :<, their_pixels,
                    "Given #{MANY_CELLS} cells for #{FEW_CELLS}, the background read as the game starts grew the written game " \
                    "from #{few} to #{many} bytes, more than the #{their_pixels} bytes of pixels the cells added once"
  end
end
