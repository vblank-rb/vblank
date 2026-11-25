# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "all/vblank/dsl/test_pack_background_set_cell"

# A block of a background's cells changed in one line (`fill_tiles`, `fill_cells`, `restore_cells`)
# shows what the same cells written one by one with `set_tile` and `set_cell` show, on every frame:
# a block partly off the map changes the cells on it, a cell written after a block in the same pass
# shows over it, and a block put back shows the map as it was declared.
class TestBackgroundCellBlocks < Minitest::Test
  include PackBackgroundSetCellGames

  COLS = 10
  ROWS = 6
  # Red and blue in a pattern of their own, so a cell put back in the wrong place shows.
  MAP = Array.new(ROWS) { |row| Array.new(COLS) { |col| ((col * 3) + row) % 4 < 2 ? "#" : "." }.join }.freeze
  FRAMES = 7

  # The game, a pass writing blocks by the block (+blocks+) or the same cells one by one. Pass 2
  # fills a block partly off the map's left and top and one partly off its right and bottom, then
  # writes one cell inside the first; pass 4 puts part of them back; pass 6 puts back the whole map.
  private def tiles_game(blocks:)
    proc do
      screen :tiled
      image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:floor, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:grass, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :set, "#" => :wall, "." => :floor, "g" => :grass
      room = background :room, tiles: :set, map: TestBackgroundCellBlocks::MAP
      t = var :t, 0
      left = var :left, -1
      top = var :top, -1
      game_loop do
        t += 1
        if t == 2
          if blocks
            room.fill_tiles left, top, 4, 3, "g"
            room.fill_tiles 7, 4, 5, 5, "."
          else
            repeat(3) { |r| repeat(4) { |c| room.set_tile c + left, r + top, "g" } }
            repeat(5) { |r| repeat(5) { |c| room.set_tile c + 7, r + 4, "." } }
          end
          room.set_tile 1, 1, "#"
        elsif t == 4
          if blocks
            room.restore_cells 0, 0, 2, left + 3
          else
            room.set_tile 0, 0, TestBackgroundCellBlocks::MAP[0][0]
            room.set_tile 1, 0, TestBackgroundCellBlocks::MAP[0][1]
            room.set_tile 0, 1, TestBackgroundCellBlocks::MAP[1][0]
            room.set_tile 1, 1, TestBackgroundCellBlocks::MAP[1][1]
          end
        elsif t == 6
          if blocks
            room.restore_cells top, top, 20, 20
          else
            TestBackgroundCellBlocks::ROWS.times do |row|
              TestBackgroundCellBlocks::COLS.times { |col| room.set_tile col, row, TestBackgroundCellBlocks::MAP[row][col] }
            end
          end
        end
      end
    end
  end

  def test_blocks_of_tiles_show_what_the_same_cells_written_one_by_one_show
    assert_same_frames(tree_of(tiles_game(blocks: true)), tree_of(tiles_game(blocks: false)))
  end

  def test_a_whole_map_put_back_shows_the_map_as_it_was_declared
    blocks = pictures_of(tree_of(tiles_game(blocks: true)))

    assert_equal blocks.first, blocks.last, "the last frame shows the first frame's map"
    refute_equal blocks.first, blocks[3], "the blocks showed between"
  end

  # On a background from the data pack told its cells by a slot: a block of the cell at a place the
  # game works out, partly off the map's right, then its middle column put back. The map is four
  # cells across and two down, at the screen's corner.
  def test_a_block_of_told_cells_shows_what_the_same_cells_written_one_by_one_show
    Dir.mktmpdir do |folder|
      blocks, one_by_one = [true, false].map do |blocks|
        program, = map_cells_game_and_file(folder, :gbc, set_cells: ->(pack) { pack[:changes] }, changes: 3) do |world|
          t = var :t, 0
          place = var :place, 0
          game_loop do
            t += 1
            place.store!(t % 3)
            if t > 1
              if t < 4
                if blocks
                  world.fill_cells 1, 0, 5, 2, place
                else
                  repeat(2) { |r| repeat(5) { |c| world.set_cell c + 1, r, place } }
                end
              end
            end
            if blocks
              world.restore_cells 2, 0, 1, 2 if t == 5
            end
          end
        end
        pictures_of(program) { |screen| cell_pixels(screen, 4, 2) }
      end

      assert_equal one_by_one.first(4), blocks.first(4), "the blocks, frame by frame"
      refute_equal blocks.first, blocks[3], "the block showed"
      assert_equal blocks.first.map { |row| row[2] }, blocks.last.map { |row| row[2] }, "the column put back"
      assert_equal one_by_one.last.map { |row| row[1] }, blocks.last.map { |row| row[1] }, "the column beside it, still filled"
    end
  end

  # --- friendly errors ---

  def test_restoring_a_background_of_several_maps_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      tree_of(proc do
        screen :tiled
        image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
        tiles :set, "#" => :wall
        rooms = background :rooms, tiles: :set, map: { hall: ["##"], cave: ["##"] }
        rooms.restore_cells 0, 0, 1, 1
      end)
    end
    assert_match(/:rooms/, error.message)
    assert_match(/several maps/, error.message)
  end

  def test_fill_cells_on_a_background_told_no_cells_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      tree_of(proc do
        screen :tiled
        image(:wall, "#" => :red) { Minitest::Test::SOLID_TILE }
        tiles :set, "#" => :wall
        room = background :room, tiles: :set, map: ["##"]
        room.fill_cells 0, 0, 1, 1, 3
      end)
    end
    assert_match(/:room/, error.message)
    assert_match(/fill_tiles/, error.message)
  end

  private def tree_of(source)
    builder = VBlank::Builder.new
    builder.instance_eval(&source)
    builder.finalize_program
    builder.program
  end

  # The picture at every frame boundary of +program+, played by this run's player, or what the
  # block reads off it.
  private def pictures_of(program)
    player = game_player
    pictures = []
    player.each_vblank { |_frame| pictures << (block_given? ? yield(player.screen) : player.screen.to_a) }
    player.run(program, frames: FRAMES)
    pictures
  end

  # Every pixel of the top left +across+ by +down+ cells of +screen+, a row of cells at a time,
  # each cell's 64 pixels together.
  private def cell_pixels(screen, across, down)
    Array.new(down) do |row|
      Array.new(across) { |col| Array.new(64) { |at| screen.pixel((col * 8) + (at % 8), (row * 8) + (at / 8)) } }
    end
  end

  private def assert_same_frames(blocks, one_by_one)
    want = pictures_of(one_by_one)
    got = pictures_of(blocks)
    want.zip(got).each_with_index { |(expected, actual), frame| assert_equal expected, actual, "frame #{frame + 1}" }
    refute_equal want.first, want[2], "the blocks changed the picture"
  end
end
