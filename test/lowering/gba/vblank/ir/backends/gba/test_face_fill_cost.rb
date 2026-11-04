# frozen_string_literal: true

require "test_helper"
require "differential"

# WHAT FILLING A FACE COSTS on the console, a pixel at a time, which is most of a frame of a place:
# one face covering the whole screen, measured by running the cartridge, under each setting of
# perspective. The same face is drawn on the interpreter too, since going faster is not allowed to
# change a pixel.
class TestFaceFillCost < Minitest::Test
  include EmulatorSupport
  include Differential

  CYCLES_A_SECOND = 16_777_216
  WHOLE_SCREEN = 240 * 160

  # A picture of 64 by 64 pixels, its colour changing every few pixels both ways, so a pixel drawn
  # from the wrong place in it shows.
  TILE = (0...64).flat_map { |down| (0...64).map { |across| ((across / 8) * 4) | (((down / 4) * 2) << 5) | (16 << 10) } }

  # A face wider and taller than the view, so every pixel of the screen is one of its pixels: two
  # wholes ahead at its left and +far+ at its right, so it leans away and perspective has work to do.
  private def whole_screen_face(perspective, see_through: nil, far: 2.0)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 64, height: 64, data: TILE, transparent: see_through
      place :wall do
        face point(-3.0, 3.0, 2.0), point(3.0, 3.0, far), point(3.0, -3.0, far), point(-3.0, -3.0, 2.0),
             picture: :tile, on_picture: [[0, 0], [64, 0], [64, 64], [0, 64]]
      end
      eye = viewer :eye, at: [0.0, 0.0, 0.0]
      game_loop { draw_place :wall, seen_by: eye, perspective: perspective }
    end
    b.finalize_program
    b.program
  end

  # The console's cycles a pixel, over a whole pass: the time the passes take, less what was left
  # over, shared out over the pixels. The edges, the rows and the drawing's own sums are in it too.
  def test_a_face_covering_the_screen_costs_under_seventeen_cycles_a_pixel_without_perspective
    assert_fill_under(17, whole_screen_face(:none), "reading its pair back cost 37")
  end

  # A picture can name a see-through colour none of its pixels has: a game that gives every
  # picture one, whether it uses it or not. Nothing on it is see-through, so it is as quick.
  def test_a_picture_naming_a_see_through_colour_it_never_uses_is_as_quick
    assert_fill_under(17, whole_screen_face(:none, see_through: 0x7C1F), "reading its pair back cost 37")
  end

  # Every eight pixels the place on the picture is worked out exactly, and between it steps two
  # pixels at a time as without perspective.
  def test_a_face_leaning_away_costs_under_thirty_cycles_a_pixel_in_perspective_every_8_pixels
    assert_fill_under(30, whole_screen_face(:every_8_pixels, far: 5.0), "a stretch at a time it cost 56")
  end

  def test_a_face_leaning_away_costs_under_ninety_cycles_a_pixel_in_perspective_every_pixel
    assert_fill_under(90, whole_screen_face(:every_pixel, far: 5.0), "a stretch at a time it cost 212")
  end

  private def assert_fill_under(most, program, before)
    rom = assemble_rom(program, name: "FILLCOST")
    profile = VBlank::Diagnostics::Profiler.run(rom, frames: 60, picture: false)
    cycles = (1 - profile.idle_share) * CYCLES_A_SECOND / profile.fps / WHOLE_SCREEN

    assert_operator cycles, :<, most, "a pixel took #{cycles.round(1)} cycles; #{before}"
    assert_backends_agree(program, frames: 3, console_frames: 30, name: "FILLCOST")
  end
end
