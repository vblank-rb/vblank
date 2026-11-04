# frozen_string_literal: true

require "test_helper"
require "differential"

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
end
