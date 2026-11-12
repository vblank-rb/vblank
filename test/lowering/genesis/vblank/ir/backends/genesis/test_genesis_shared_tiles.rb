# frozen_string_literal: true

require "test_helper"
require "many_tiles"
require "all/vblank/builder/test_pack_poses_sharing_tiles"

# WHAT A SCREEN DRAWN FROM ONE SLOT OF AN ORIGINAL'S TILES COSTS THE GENESIS'S VIDEO MEMORY. A retail
# game loads a screen's tiles once, and every map cell and sprite piece names them by number, turned
# by the console's own bits. So the build of such a screen holds each of the slot's tiles it shows
# once, whoever draws it and whichever way round. These read the video memory the console drew from.
class TestGenesisSharedTiles < Minitest::Test
  include SharedSlotTilesGame

  Genesis = VBlank::IR::Backends::Genesis
  Tiles = Genesis::Runtime::Tiles

  # An entry of the sprite table as the console keeps it.
  Entry = Data.define(:left, :top, :columns, :rows, :tile, :mirrored, :upside_down)

  def test_the_slots_tiles_the_screen_shows_are_in_video_memory_once
    Dir.mktmpdir do |folder|
      memory = video_memory_after(shared_slot_game(folder))

      assert_equal TILES_SHOWN, tiles_held(memory), "tiles in video memory, the blank one not counted"
    end
  end

  # A pose the game mirrors is drawn from the tiles of the pose it mirrors.
  def test_a_pose_the_game_mirrors_takes_no_tiles_of_its_own
    Dir.mktmpdir do |folder|
      memory = video_memory_after(shared_slot_game(folder) { |_pack| sprite mirror(:leap), at: [80, 80] })

      assert_equal TILES_SHOWN, tiles_held(memory)
    end
  end

  # Each piece of a frame is an entry of the table, wherever it sits from the origin: :walk's two,
  # :turn's two and :leap's two, each the size the frame gives it.
  def test_each_piece_of_a_frame_is_one_entry_of_the_sprite_table
    Dir.mktmpdir do |folder|
      entries = sprite_entries(video_memory_after(shared_slot_game(folder)))
      expected = POSES.flat_map do |name, pieces|
        left, top = SPRITES_AT.fetch(name)
        pieces.map { |piece| [left + ORIGIN[0] + piece.x, top + ORIGIN[1] + piece.y, piece.columns, piece.rows] }
      end

      assert_equal expected.sort, entries.map { |entry| [entry.left, entry.top, entry.columns, entry.rows] }.sort
    end
  end

  # :turn's first piece is :walk's mirrored, so both entries name one run of tiles, and :turn's is
  # turned by the console.
  def test_a_mirrored_piece_names_the_same_tiles_turned_by_the_console
    Dir.mktmpdir do |folder|
      entries = sprite_entries(video_memory_after(shared_slot_game(folder)))
      walk, turn = %i[walk turn].map do |name|
        left, top = SPRITES_AT.fetch(name)
        entries.find { |entry| [entry.left, entry.top] == [left + ORIGIN[0], top + ORIGIN[1] - 4] }
      end

      assert_equal walk.tile, turn.tile, "the first tile both entries name"
      assert_equal [false, true], [walk.mirrored, turn.mirrored], "which entry the console mirrors"
    end
  end

  # A cell and the same cell mirrored name one tile, and so do a cell and a pose's piece.
  def test_a_mirrored_cell_names_the_tile_the_plain_cell_names
    Dir.mktmpdir do |folder|
      memory = video_memory_after(shared_slot_game(folder))
      plain, mirrored = memory.byteslice(Tiles::PLANE_A_AT, 4).unpack("n2")

      assert_equal plain & 0x7FF, mirrored & 0x7FF, "the tile the two cells name"
      assert_equal [0, 0x800], [plain & 0x800, mirrored & 0x800], "which cell the console mirrors"
    end
  end

  # The refusal counts what the screen wants and names what takes the most.
  def test_too_many_tiles_are_refused_saying_how_many_and_naming_the_biggest_takers
    error = assert_raises(Genesis::Art::TooManyTiles) do
      Genesis.new.build(program_of do
        screen :tiled
        half = (Genesis::Art::MOST_TILES / 2) + 6
        near = ManyTiles.declare(self, :near_set, half, :red)
        far = ManyTiles.declare(self, :far_set, half + 20, :blue, from: half)
        background :far, tiles: :far_set, map: far
        background :near, tiles: :near_set, map: near
        game_loop { wait_vblank }
      end)
    end

    half = (Genesis::Art::MOST_TILES / 2) + 6
    assert_includes error.message, "need #{(half * 2) + 20} "
    assert_includes error.message, "room for #{Genesis::Art::MOST_TILES}"
    assert_match(/background :far \(#{half + 20}\).*background :near \(#{half}\)/m, error.message)
  end

  private

  def program_of(&)
    builder = Builder.new
    builder.instance_eval(&)
    builder.finalize_program
    builder.program
  end

  # The console's video memory once the game has drawn its screen.
  def video_memory_after(program, frames: 30)
    rom = VBlank::Console.for(:genesis).builder.cartridge_for(program, title: "SHARED")
    VBlank::Diagnostics::Emulator.with_cartridge(rom, file_name: "game.gen") do |core|
      frames.times { core.run_frame }
      core.vram
    end
  end

  # How many tiles of the room for tiles hold a picture: tile 0 is kept blank and not counted.
  def tiles_held(memory)
    (1..Genesis::Art::MOST_TILES).count { |tile| memory.byteslice(tile * 32, 32).bytes.any?(&:nonzero?) }
  end

  # Each entry of the sprite table, as the console walks it from row 0 by each row's link.
  def sprite_entries(memory)
    table = memory.byteslice(Tiles::SPRITES_AT, 80 * 8)
    entries = []
    row = 0
    loop do
      top, size_link, tile, left = table.byteslice(row * 8, 8).unpack("n4")
      size = size_link >> 8
      entries << Entry.new(left: (left & 0x1FF) - Tiles::SPRITE_ORIGIN, top: (top & 0x3FF) - Tiles::SPRITE_ORIGIN,
                           columns: (size >> 2) + 1, rows: (size & 3) + 1, tile: tile & 0x7FF,
                           mirrored: tile.anybits?(0x800), upside_down: tile.anybits?(0x1000))
      row = size_link & 0x7F
      break if row.zero? || entries.length > 80
    end
    entries
  end
end
