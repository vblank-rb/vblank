# frozen_string_literal: true

require "test_helper"
require "digest"
require "stringio"
require "tmpdir"
require "made_up_original_layouts"

# A SPEECH BOX AS A GENESIS GAME OPENS ONE: a pass lays a box of nearly two hundred cells into a
# background from the data pack (a top edge, a left edge, the inside, a right edge and a bottom
# edge, each a block of one cell the game works out), and a later pass puts back the cells of the
# map the box covered. A retail game queues one command for each block and the blank writes the
# cells straight into the video chip, so each pass is a small part of a frame and the box shows on
# the frame after it.
class TestGenesisCellBlocks < Minitest::Test
  # Tile 0 draws nothing; every other tile three colours in a pattern of its own number.
  TILES = (0..96).map { |n| (0...64).map { |at| n.zero? ? 0 : 1 + (((at % 8) + (2 * (at / 8)) + n) % 3) } }.freeze
  CELL = ->(tile) { tile | (1 << 15) }
  ACROSS = 64
  DOWN = 32
  MAP = Array.new(ACROSS * DOWN) { |at| CELL.(1 + ((at + (at / ACROSS)) % 5)) }.freeze
  COLORS_AT = 0x40
  MAP_AT = 0x400
  TILES_AT = MAP_AT + (MAP.length * 2)
  # The box's cells are the told cells from here on: an edge, the inside, another edge.
  BOX_BASE = CELL.(10)
  TOLD = BOX_BASE..(BOX_BASE + 40)

  BOX_LEFT = 3
  BOX_TOP = 5
  BOX_ACROSS = 27
  BOX_DOWN = 7
  # Every pass lays the box or puts it back by turns, four passes apart.
  EVERY = 4
  PASSES = 24

  # How much of a frame the pass that lays the box, or puts it back, may take. Each block is a
  # few words noted in the queue, and the blank writes a word a cell: the pass is little more
  # than an ordinary one. Written a cell at a time, the box took more than a whole frame.
  MOST_OF_A_FRAME = 0.1

  VBlank::Testing::InRactors.share_constants(self)

  TAPE = VBlank::Playthroughs::Tape.parse(<<~TAPE)
    vblank tape 1
    recorded on: CELL BLOCKS 0x00000000
    starts from: power-on
  TAPE

  def self.original(folder)
    tiles = TILES.map(&MadeUpOriginalLayouts::HIGH_HALF_FIRST).join
    colors = MadeUpOriginalLayouts::LEVELS.map { |red, green, blue| (red << 1) | (green << 5) | (blue << 9) }.pack("n*")
    copy = "\0".b * (TILES_AT + tiles.bytesize)
    copy[COLORS_AT, colors.bytesize] = colors
    copy[MAP_AT, MAP.length * 2] = MAP.pack("n*")
    copy[TILES_AT, tiles.bytesize] = tiles
    path = File.join(folder, "made_up.bin")
    File.binwrite(path, copy)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: { "MADE_UP_ROM" => path }, platform: :genesis,
                               settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => Digest::SHA1.hexdigest(copy), "size" => copy.bytesize } })
  end

  # The game, reading the original in +folder+. The box is laid in five blocks whose cells are
  # worked out from +edge+, and put back with the cells around it, a column and a row more each way.
  # A letter is written into the box after it is laid, in the same pass, and shows over it.
  def self.game(folder)
    from = original(folder)
    VBlank.game("CELL BLOCKS", consoles: %i[genesis]) do
      screen :tiled
      pack = data_pack from: from, version: "1" do |slots|
        slots.tiles :video, at: TILES_AT, count: TILES.length, colors: 16
        slots.numbers :map, at: MAP_AT, count: MAP.length, width: :half, signed: false
        slots.colors :palette, at: COLORS_AT, count: 16
      end
      world = background :world, tiles: pack[:video], map: pack[:map], colors: pack[:palette], across: ACROSS, cell: 8,
                                 set_cells: TOLD
      t = var :t, 0
      left = var :left, BOX_LEFT
      top = var :top, BOX_TOP
      edge = var :edge, 0
      game_loop do
        t += 1
        edge = (t / (EVERY * 2)) % 3
        if t % (EVERY * 2) == EVERY
          world.fill_cells left, top, BOX_ACROSS, 1, BOX_BASE + edge
          world.fill_cells left, top + 1, 1, BOX_DOWN - 2, BOX_BASE + edge + 1
          world.fill_cells left + 1, top + 1, BOX_ACROSS - 2, BOX_DOWN - 2, BOX_BASE + edge + 2
          world.fill_cells left + BOX_ACROSS - 1, top + 1, 1, BOX_DOWN - 2, BOX_BASE + edge + 3
          world.fill_cells left, top + BOX_DOWN - 1, BOX_ACROSS, 1, BOX_BASE + edge + 4
          world.set_cell left + 2, top + 2, BOX_BASE + 20
        elsif (t % (EVERY * 2)).zero?
          world.restore_cells left - 1, top - 1, BOX_ACROSS + 2, BOX_DOWN + 2
        end
      end
    end
  end

  def test_the_box_laid_and_put_back_shows_what_the_interpreter_shows
    Dir.mktmpdir do |folder|
      game_player.run(TestGenesisCellBlocks.game(folder).program(console: :genesis), frames: PASSES)
    end
  end

  # A pass that changes nearly as many cells as the queue holds, then a block, then a cell inside
  # it: the queue is written early, in order, and the cell lands over the block. A later pass fills
  # a block and then hands the scene over, whose map goes up over it.
  def test_blocks_in_a_full_queue_and_under_a_map_put_up_show_what_the_interpreter_shows
    game = VBlank.game("FULL BLOCKS", consoles: %i[genesis]) do
      screen :tiled
      image(:red_art, "#" => :red) { Minitest::Test::SOLID_TILE }
      image(:blue_art, "#" => :blue) { Minitest::Test::SOLID_TILE }
      image(:green_art, "#" => :green) { Minitest::Test::SOLID_TILE }
      tiles :set, "#" => :red_art, "." => :blue_art, "g" => :green_art
      tick = var :tick, 0
      state = var :state, 0
      scene(:field) do
        field = background :field, tiles: :set, map: Array.new(28) { "#." * 20 }
        tick += 1
        if tick == 2
          repeat(255) { |i| field.set_tile i % 40, i / 40, "." }
          field.fill_tiles 5, 10, 10, 4, "g"
          field.set_tile 6, 11, "#"
        end
        if tick == 4
          field.fill_tiles 0, 20, 40, 3, "g"
          field.restore_cells 4, 9, 3, 3
        end
        if tick == 5
          field.fill_tiles 0, 0, 40, 2, "g"
          state.store! 1
        end
      end
      scene(:other) { background :other, tiles: :set, map: Array.new(28) { "." * 40 } }
      game_loop do
        case_var(:state) do
          when_val 0, :field
          when_val 1, :other
        end
      end
    end

    game_player.run(game.program(console: :genesis), frames: 8)
  end

  def test_the_passes_that_lay_the_box_and_put_it_back_fit_a_frame_with_lines_to_spare
    Dir.mktmpdir do |folder|
      rom = TestGenesisCellBlocks.game(folder).build_rom(console: :genesis, out: StringIO.new, err: StringIO.new, profile: false)
      still = rom.profile(out: StringIO.new, frames: PASSES)
      frames = rom.profile(out: StringIO.new, tape: TAPE, frames: still.measured_frames)

      assert_equal({ 1 => PASSES }, still.passes_by_frames, "every pass fits in one frame")
      assert_empty frames.held.map(&:frame), "every frame shows a new picture"
      assert_operator frames.busiest.awake_share, :<=, MOST_OF_A_FRAME,
                      "the busiest pass takes #{(frames.busiest.awake_share * 100).round(1)}% of a frame"
    end
  end
end
