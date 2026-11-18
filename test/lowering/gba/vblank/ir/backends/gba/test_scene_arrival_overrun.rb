# frozen_string_literal: true

require "test_helper"

# A SCENE WHOSE SETUP RUNS PAST THE GAP BETWEEN PICTURES, on the console. Putting a scene's
# backgrounds up sends their pictures and maps into video memory with the layers switched off, and
# the console goes on drawing while that happens. When the work is bigger than the gap, the layers
# come back on part way down the picture: rows above are the backdrop, rows below are the scene, and
# where the line falls depends on how many cycles the pass spent getting there. So two builds of
# one game that differ anywhere before it disagree on that picture, and the player sees a torn one.
#
# The layers stay off for the rest of a picture the setup ran into, and come on in the next gap
# (GBATEK, DISPCNT: a write takes effect from the line being drawn). The first picture is then the
# backdrop from top to bottom, whatever the timing, and the one after it is the scene, whole.
class TestSceneArrivalOverrun < Minitest::Test
  HANDED_OVER_AT = 4
  TITLE = (0...64).map { |at| at.even? ? :green : :blue }

  # Tile +n+: white then red at the start of every row, so a row the scene shows is never one
  # colour (and a row of the backdrop always is), and +n+ in binary in the rest, so no two tiles
  # are alike and none is kept once for several.
  def self.numbered_tile(n)
    (0...64).map do |at|
      column = at % 8
      next :white if column.zero?
      next :red if column == 1

      n[((at / 8) * 6) + column - 2].zero? ? :red : :white
    end
  end
  WIDE = 96 # a map wider than the console keeps, so the view of it is filled as the scene comes up

  # The line of the gap a late handover waits for before the scene takes over: near the gap's end
  # (line 227), so the setup after it runs into the picture however quick it is.
  LATE_LINE = 215

  # A title, then a scene of +layers+ backgrounds, each a map of +tile_count+ different tiles, wide
  # enough that the view of it is filled as the scene comes up. With +late+ the pass that hands over
  # spends the gap until LATE_LINE first, read off the console's line counter. With +halts+ the scene
  # stops the game on its first pass, as an end screen does, so no wait for a frame follows it.
  private def handed_over(layers:, tile_count:, late: false, halts: false)
    title_tile = TITLE
    side = WIDE
    handed_over_at = HANDED_OVER_AT
    late_line = LATE_LINE
    b = Builder.new
    b.extend(VBlank::Builder::Debug)
    b.instance_eval do
      screen :tiled
      tile_count.times { |n| image(:"stripe_#{n}", width: 8, height: 8, data: TestSceneArrivalOverrun.numbered_tile(n)) }
      tiles :stripes, (0...tile_count).to_h { |n| [n, :"stripe_#{n}"] }
      image(:title_tile, width: 8, height: 8, data: title_tile)
      tiles :title_tiles, { 0 => :title_tile }
      map = Array.new(side) { |row| Array.new(side) { |col| ((row * side) + col) % tile_count } }
      state = var :state, 0
      pass = var :pass, 0
      scene(:title) { background :title, tiles: :title_tiles, map: Array.new(20) { [0] * 30 } }
      scene(:play) do
        layers.times { |layer| background :"layer_#{layer}", tiles: :stripes, map: map }
        halt if halts
      end
      game_loop do
        pass += 1
        state = 1 if pass == handed_over_at
        if late && pass == handed_over_at
          line = read_scanline
          while line < late_line
            line = read_scanline
          end
        end
        case_var(:state) do
          when_val 0, :title
          when_val 1, :play
        end
      end
    end
    b.finalize_program
    b.program
  end

  # Each picture from the handover on, as the rows of it that are one colour (the backdrop).
  private def backdrop_rows_from_handover(program)
    rom = assemble_rom(program, name: "OVERRUN")
    reader = VBlank::Diagnostics::Verifier.new(rom, frames: 0, vars: rom.var_addresses)
    (1..(HANDED_OVER_AT + 4)).filter_map do
      reader.step
      next unless reader.var(:state) == 1

      picture = reader.frame_gba
      (0...160).select { |row| picture[row * 240, 240].uniq.one? }
    end
  end

  def test_the_first_picture_of_a_scene_that_overruns_the_gap_is_the_backdrop_whole
    pictures = backdrop_rows_from_handover(handed_over(layers: 3, tile_count: 900, late: true))

    torn = pictures.reject { |rows| rows.empty? || rows.length == 160 }
    assert_empty torn, "a picture shows the backdrop on some rows and the scene on others: #{pictures.map(&:length)}"
    assert_equal 160, pictures.first.length, "the first picture of the scene is the backdrop: #{pictures.map(&:length)}"
    assert_empty pictures.last, "the scene is up whole after: #{pictures.map(&:length)}"
  end

  # The layers held off come on in the next gap whatever the game does then, a stop included.
  def test_a_scene_that_overruns_the_gap_and_stops_the_game_is_up_on_the_next_picture
    pictures = backdrop_rows_from_handover(handed_over(layers: 3, tile_count: 900, late: true, halts: true))

    assert_equal 160, pictures.first.length, "the first picture of the scene is the backdrop: #{pictures.map(&:length)}"
    assert_empty pictures[1], "the picture after shows the scene: #{pictures.map(&:length)}"
    assert_empty pictures.last, "and the scene stays up: #{pictures.map(&:length)}"
  end

  def test_a_scene_whose_setup_fits_the_gap_is_up_on_its_first_picture
    pictures = backdrop_rows_from_handover(handed_over(layers: 1, tile_count: 4))

    assert_empty pictures.first, "the first picture of a scene that fits the gap is the scene: #{pictures.map(&:length)}"
  end
end
