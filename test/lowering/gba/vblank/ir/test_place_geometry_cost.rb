# frozen_string_literal: true

require "test_helper"
require "differential"
require "place_games"

# WHAT A PLACE'S POINTS COST on the console before anything is filled: a grid of small faces far
# off, each a few pixels on the screen and sharing its corners with its neighbours, so nearly all
# of a pass is turning, cutting and projecting (IR::PlaceDrawing) and setting each face up to be
# filled. Measured by running the cartridge, with the same picture drawn on the interpreter.
class TestPlaceGeometryCost < Minitest::Test
  include EmulatorSupport
  include Differential

  CYCLES_A_SECOND = 16_777_216
  SIDE = 10
  POINTS = (SIDE + 1) * (SIDE + 1)

  private def grid
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 8, height: 8, data: (0...64).map { |at| (at * 4) | (12 << 10) }
      place :grid do
        at = Array.new(SIDE + 1) do |row|
          Array.new(SIDE + 1) { |col| point((col - (SIDE / 2)) * 1.0, ((SIDE / 2) - row) * 1.0, 40.0) }
        end
        SIDE.times do |row|
          SIDE.times do |col|
            face at[row][col], at[row][col + 1], at[row + 1][col + 1], at[row + 1][col],
                 picture: :tile, on_picture: [[0, 0], [8, 0], [8, 8], [0, 8]]
          end
        end
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop do
        clear_screen :black
        draw_place :grid, seen_by: eye, perspective: :none
      end
    end
    b.finalize_program
    b.program
  end

  # Each point is a corner of up to four faces; turned once a drawing rather than once a face,
  # a pass costs well under what it did when each face turned its own corners.
  def test_a_grid_of_small_faces_costs_under_six_thousand_cycles_a_point
    program = grid
    profile = VBlank::Diagnostics::Profiler.run(assemble_rom(program, name: "GEOMCOST"), frames: 60, picture: false)
    cycles = (1 - profile.idle_share) * CYCLES_A_SECOND / profile.fps / POINTS

    assert_operator cycles, :<, 6000, "a point took #{cycles.round} cycles; turned once a face it took 6270"
    assert_backends_agree(program, frames: 3, console_frames: 30, name: "GEOMCOST")
  end

  # A FLOOR OF ABOUT A THOUSAND FACES drawn whole every pass, as a level read from a file is, about
  # half of them behind the viewer or beside the view and most of the rest far off and under a row
  # high (PlaceGames.big_floor). A face out of view is passed over by its points' codes before any of
  # its corners is read, and one under a row high before it is handed to the fill, so the pass goes
  # on the faces that show. When every face was read, cut and tested before anything passed it over,
  # the floor drew half as often.
  def test_a_floor_of_a_thousand_faces_draws_at_least_eight_times_a_second
    program = PlaceGames.big_floor(perspective: :none)
    profile = VBlank::Diagnostics::Profiler.run(assemble_rom(program, name: "FLOORCOST"), frames: 120, picture: false)

    assert_operator profile.fps, :>=, 8.0, "the floor drew #{profile.fps} times a second"
    assert_backends_agree(program, frames: 2, console_frames: 30, name: "FLOORCOST")
  end

  # THE SAME FLOOR IN PERSPECTIVE, as a place is drawn unless a game asks otherwise. Its rows are
  # short, two or three stretches of eight pixels and a few pixels over, so what a row costs to
  # start and to end is most of what perspective adds. A row is drawn from its first stretch to its
  # last pixel by one run that keeps its numbers in registers, the pixels left over included.
  # When every row went back to the general way for those, a stretch at a time, a pass took nine
  # frames, which is under seven drawings a second.
  #
  # What each face costs before it is filled is most of the rest: a face passed over reads only its
  # corners' codes, the faces table is read without holding its index, the fill is handed its
  # corners in its own words, and a picture already handed over is not handed over again. When a
  # face read its corners' codes twice and every fill copied its corners, the floor drew seven and a
  # half times a second.
  def test_a_floor_of_a_thousand_faces_in_perspective_draws_at_least_eight_times_a_second
    program = PlaceGames.big_floor(perspective: :every_8_pixels)
    profile = VBlank::Diagnostics::Profiler.run(assemble_rom(program, name: "FLOORCOST"), frames: 120, picture: false)

    assert_operator profile.fps, :>=, 8.0, "the floor drew #{profile.fps} times a second"
    assert_backends_agree(program, frames: 2, console_frames: 30, name: "FLOORCOST")
  end
end
