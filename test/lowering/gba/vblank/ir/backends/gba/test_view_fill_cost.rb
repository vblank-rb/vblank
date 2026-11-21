# frozen_string_literal: true

require "test_helper"
require "differential"

# What filling a big map's whole view costs, on the console. A background whose map is bigger than
# the console's grid has the cells around its view written into the grid as a scene puts it up, and
# again whenever the view jumps (see GBA::MapStreaming). That fill is 21 rows of 31 cells, and it
# runs in the gap between pictures with the layers off, so the lines it takes are lines the scene
# does not have.
#
# The budget is the copying engine's (GBATEK, "DMA Transfers"): a row of the view is one or two
# copies of halfwords out of the cartridge, so a layer's fill is a few lines, where a loop writing
# a cell at a time spends several times that.
class TestViewFillCost < Minitest::Test
  include Differential

  Debug = VBlank::Builder::Debug

  SIDE = 96 # wider and taller than the console's biggest grid, so the map is streamed
  LINES_IN_A_FRAME = 228

  # The most lines putting up one more streamed layer may take, the fill and the rest of its setup
  # together, read off the console's line counter (VCOUNT). The budget is what the copying engine
  # takes for a row or two at a time, with a line to spare, and a fill a cell at a time does not fit it.
  MOST_LINES_A_LAYER = 4

  # A scene that puts up +layers+ big backgrounds, reading the console's line counter before and
  # after, then stops.
  private def put_up(layers)
    side = SIDE
    b = Builder.new
    b.extend(Debug)
    b.instance_eval do
      screen :tiled
      4.times do |n|
        image(:"cell_#{n}", width: 8, height: 8, data: Array.new(64) { |at| at.even? ? :red : %i[white green blue black][n] })
      end
      tiles :cells, (0...4).to_h { |n| [n, :"cell_#{n}"] }
      map = Array.new(side) { |row| Array.new(side) { |col| (row + col) % 4 } }
      before = var :before, 0
      after = var :after, 0
      state = var :state, 0
      pass = var :pass, 0
      scene(:title) { nil }
      scene(:play) do
        layers.times { |layer| background :"layer_#{layer}", tiles: :cells, map: map }
      end
      game_loop do
        pass += 1
        state = 1 if pass == 3
        before = read_scanline
        call({ 0 => :title, 1 => :play }, number: :state)
        after = read_scanline
        halt if state == 1
      end
    end
    b.finalize_program
    b.program
  end

  # Lines from the first reading to the second, round the end of the frame if need be.
  private def lines_spent(layers)
    backend = GBA.new
    rom = ROM.assemble(backend.lower(put_up(layers)), title: "VIEWFILL", maker: "01")
    reader = assert_emulator_loads_rom(rom, frames: 8, vars: backend.var_addresses)
    (reader.var(:after) - reader.var(:before)) % LINES_IN_A_FRAME
  end

  def test_a_streamed_layer_goes_up_in_a_few_lines
    one = lines_spent(1)
    two = lines_spent(2)

    assert_operator two - one, :<=, MOST_LINES_A_LAYER, "lines for the second layer (one layer took #{one}, two #{two})"
  end

  # Where the view jumps to, a pass at a time, in pixels: past the map's top-left corner, across
  # the grid's 32-cell edge, past its bottom-right corner, wholly off the map to the left and
  # below, and then on a map narrower and shorter than the view.
  JUMPS = [[-40, -24], [163, 325], [540, 500], [-300, 8], [400, 720]].freeze
  ON_THE_SMALL_MAP = [[-12, -12], [83, 4]].freeze

  # Tile +n+: its top-left pixel white and the rest +n+ in binary, red on blue, so a cell copied
  # from the wrong place in the map shows.
  def self.numbered_tile(n)
    (0...64).map { |at| at.zero? ? :white : (n[(at - 1) % 4].zero? ? :red : :blue) }
  end

  private def jumping
    jumps = JUMPS
    small_jumps = ON_THE_SMALL_MAP
    b = Builder.new
    b.instance_eval do
      screen :tiled
      16.times { |n| image(:"cell_#{n}", width: 8, height: 8, data: TestViewFillCost.numbered_tile(n)) }
      tiles :cells, (0...16).to_h { |n| [n, :"cell_#{n}"] }
      big = Array.new(70) { |row| Array.new(80) { |col| ((row * 7) + (col * 3)) % 16 } }
      small = Array.new(12) { |row| Array.new(20) { |col| ((row * 5) + col) % 16 } }
      ground = background :ground, tiles: :cells, map: { big: big, small: small }
      pass = var :pass, 0
      game_loop do
        pass += 1
        jumps.each_with_index { |(x, y), at| ground.scroll_to(x, y) if pass == at + 2 }
        ground.show_map :small if pass == jumps.length + 2
        small_jumps.each_with_index { |(x, y), at| ground.scroll_to(x, y) if pass == jumps.length + 2 + at }
      end
    end
    b.finalize_program
    b.program
  end

  # The cells a whole fill writes are the interpreter's, wherever the view lands.
  def test_a_view_filled_whole_shows_what_the_interpreter_shows
    assert_backends_agree(jumping, frames: 2..(JUMPS.length + ON_THE_SMALL_MAP.length + 3), name: "VIEWJUMP")
  end
end
