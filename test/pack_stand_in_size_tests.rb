# frozen_string_literal: true

require "tmpdir"
require "all/vblank/builder/test_pack_pose_bank_colors"
require "all/vblank/builder/test_pack_tile_pictures"
require "all/vblank/builder/test_pack_background_areas"

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
# are embedded from, and the game as Ruby with its runtime; and which lowering it is (#lowering_class),
# for what the game keeps of the file while it runs. Played with the games of PackPoseBankColorGames and PackTilePictureGames, which
# the registry (PackGames, test/pack_games.rb) holds alike to their all-in-one builds on every pass.
module PackStandInSizeTests
  LEFT_OUT = VBlank::Cartridge::Options.new(for_computer: true, pack_at_start: true)

  # The poses as the registry's game has them, and as big as a title's actor.
  SMALL_POSE = [16, 8].freeze
  BIG_POSE = [120, 96].freeze
  # A map, and one four times as many cells.
  FEW_CELLS = 24
  MANY_CELLS = 96

  # A map's slot of colours in two banks, and in six. Each bank is a list the game can draw with.
  FEW_BANKS = 2
  MANY_BANKS = 6

  # How many bytes a pixel is kept in at the least: sixteen bits.
  PIXEL_BYTES = 2
  # How many bytes a tile's picture of sixteen colours is kept in at the least: half a byte a pixel.
  PICTURE_BYTES = 32

  # The games' builders, each in its own object, since the two modules each name a made-up original
  # of their own by one name.
  class Actors
    include PackPoseBankColorGames
  end

  class Belts
    include PackTilePictureGames
  end

  class Rooms
    include PackBackgroundAreaGames

    # The world of +rooms+ rooms, each +across+ by +down+ cells over one slot of four tiles, built
    # with its pack left out.
    def world_left_out(folder, rooms, across, down)
      names = Array.new(rooms) { |at| :"room_#{at}" }
      world_game_and_file(folder, PackBackgroundAreaGames.world_areas(names, across, down), across, options: LEFT_OUT).first
    end
  end

  # How many different tiles as drawn the world's slot can make: four tiles, in two banks or a bank
  # past them, each turned four ways, and one for a tile past the slot.
  WORLD_TILES_AS_DRAWN = (4 * 3 * 4) + 1
  # How many bytes of pixels a tile is kept in as the game runs.
  TILE_PIXEL_BYTES = 64 * PIXEL_BYTES

  # A BACKGROUND READ AS THE GAME STARTS HOLDS THE TILES ITS SLOT CAN DRAW, NOT A TILE FOR EVERY CELL:
  # the cells name the tiles, as the console's map does. So rooms over one slot of tiles, however big
  # and however many, take the room of what the slot can draw once.
  def test_a_world_of_rooms_over_one_tile_slot_holds_what_the_slot_can_draw_once
    one, three = [1, 3].map do |rooms|
      Dir.mktmpdir { |folder| lowering_class.new(program_played(Rooms.new.world_left_out(folder, rooms, 40, 24))).start_file_tile_room_bytes }
    end
    most = (WORLD_TILES_AS_DRAWN + BANK_STAND_INS) * TILE_PIXEL_BYTES

    assert_operator one, :<=, most, "one room of 960 cells holds #{one} bytes of tiles, more than its slot can draw"
    assert_operator three - one, :<=, 2 * BANK_STAND_INS * TILE_PIXEL_BYTES,
                    "three rooms over the same slot hold #{three} bytes of tiles, one holds #{one}: more than two rooms' stand-ins more"
  end

  # The stand-in tile the game holds for each bank of colours in each area, before the cells' tiles.
  BANK_STAND_INS = 2

  def test_poses_read_at_start_made_bigger_cost_the_written_game_less_than_one_pose_of_pixels
    small, big = [SMALL_POSE, BIG_POSE].map do |size|
      Dir.mktmpdir { |folder| written_bytes(program_played(Actors.new.recolored_actors_builder(folder, size: size, options: LEFT_OUT).program)) }
    end
    one_pose = ((BIG_POSE.inject(:*) - SMALL_POSE.inject(:*)) * PIXEL_BYTES)

    assert_operator big - small, :<, one_pose,
                    "Made #{BIG_POSE.join('x')} from #{SMALL_POSE.join('x')}, the poses read as the game starts grew the written " \
                    "game from #{small} to #{big} bytes, more than one pose's #{one_pose} bytes of pixels more"
  end

  # ...and A POSE IS HELD ONCE AS THE GAME RUNS, HOWEVER MANY SETS OF COLOURS DRAW IT: its pixels are
  # the places of its frame, and each set it is drawn in is a list of those places' colours. The
  # actors' two poses are each drawn in the three sets their lists can hold, so a copy of each pose
  # for every set would be three times the room.
  def test_poses_read_at_start_drawn_in_several_sets_are_held_once_as_the_game_runs
    room = Dir.mktmpdir do |folder|
      program = program_played(Actors.new.recolored_actors_builder(folder, size: BIG_POSE, options: LEFT_OUT).program)
      lowering_class.new(program).start_file_image_room_bytes
    end
    poses = PackPoseBankColorGames::ACTOR_POSES.uniq.length
    once = poses * BIG_POSE.inject(:*) * PIXEL_BYTES

    assert_operator room, :<, once + SETS_OF_COLORS_BYTES,
                    "The #{poses} poses of #{BIG_POSE.join('x')}, each drawn in three sets of colours, take #{room} bytes as " \
                    "the game runs, more than the #{once} bytes of one copy of each and their sets of colours"
  end

  # Room enough for the colours of every set a pose is drawn in: a few lists of 256 colours.
  SETS_OF_COLORS_BYTES = 8 * 256 * PIXEL_BYTES

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

  # A TILE TAKING TURNS THROUGH PICTURES, ITS SLOT OF COLOURS IN MORE BANKS: each bank has a run of
  # the tile of its own, and every run copies from one table of the pictures, read from the file
  # as the game starts. So what the game keeps of the file while it runs (#start_file_bytes) grows
  # by the banks' colours, never by the pictures again for each bank.
  def test_a_tiles_pictures_read_at_start_are_held_once_whatever_the_banks_of_colors
    few, many = [FEW_BANKS, MANY_BANKS].map do |banks|
      words = PackTilePictureGames.title_belt_words(FEW_CELLS)
      Dir.mktmpdir { |folder| start_file_bytes(program_played(Belts.new.title_belt_game_and_file(folder, words: words, banks: banks, options: LEFT_OUT).first)) }
    end
    pictures = PackTilePictureGames::BELT.length * VBlank::IR::StartFile::MovingTile::TURNS.length * PICTURE_BYTES

    assert_operator many - few, :<, pictures,
                    "Given #{MANY_BANKS} banks of colours for #{FEW_BANKS}, what the game keeps of the file as it runs grew " \
                    "from #{few} to #{many} bytes, more than the #{pictures} bytes of the belt's pictures held once"
  end

  # ...and A SHOW COPIES THE PICTURE INTO THE RUNS OF THE BANKS THE MAP POINTS AT ALONE: which
  # banks a cell names is in the file, so the game learns it as it starts. The map draws the belt
  # in two banks of six, so two runs hold the belt's pictures, and the other four were never copied
  # into at all, from power-on on. The runs are the framework's own lists, which only the lowered
  # game is asked about: the interpreter copies into every run, and shows the same picture.
  def test_a_show_copies_into_the_runs_of_the_banks_the_map_draws_from_alone
    copied = Dir.mktmpdir do |folder|
      words = PackTilePictureGames.title_belt_words(FEW_CELLS)
      _, file = Belts.new.title_belt_game_and_file(folder, words: words, banks: MANY_BANKS)
      program, = Belts.new.title_belt_game_and_file(folder, words: words, banks: MANY_BANKS, options: LEFT_OUT)
      run = headless_run.hand_file(file).run(program_played(program), frames: SHOWS)
      (0...MANY_BANKS).count { |bank| run.list(belt_run_list(bank)).any?(&:nonzero?) }
    end

    assert_equal FEW_BANKS, copied, "the runs a show copied the belt into, of #{MANY_BANKS}"
  end

  # The passes the belt game plays: each shows a picture, the second one from the third pass on.
  SHOWS = 6

  # The list the run of the belt for +bank+ shows its picture from (Builder::PackTilePictures
  # names a background's runs in the order of its banks).
  private def belt_run_list(bank) = VBlank::Messages::MadeNames.make(:tile_pictures_part, group: :"belt_run_#{bank}", part: :shown)

  # Each lowering here builds on Computer::Lowering, which counts what the game keeps of the file.
  private def start_file_bytes(program) = lowering_class.new(program).start_file_array_bytes
end
