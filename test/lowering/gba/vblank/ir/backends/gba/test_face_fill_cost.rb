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

  # A shading of the tile's own colours over 32 levels, each level a colour further down the list,
  # so lighting it adds no colour to the screen's palette.
  TILE_COLORS = TILE.uniq
  LEVELS = (0...32).map { |level| (0...TILE_COLORS.length).map { |place| place * level / 31 } }

  # A face wider and taller than the view, so every pixel of the screen is one of its pixels: two
  # wholes ahead at its left and +far+ at its right, so it leans away and perspective has work to do.
  # +lit+ lights it through the shading, a different light at each corner.
  # +data+ is the picture's pixels, the tile's unless given.
  private def whole_screen_face(perspective, see_through: nil, far: 2.0, lit: false, data: TILE)
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      image :tile, width: 64, height: 64, data: data, transparent: see_through
      shading :dark, colors: TILE_COLORS, levels: LEVELS
      place :wall, shading: lit ? :dark : nil do
        face point(-3.0, 3.0, 2.0), point(3.0, 3.0, far), point(3.0, -3.0, far), point(-3.0, -3.0, 2.0),
             picture: :tile, on_picture: [[0, 0], [64, 0], [64, 64], [0, 64]], light: [0.2, 1.0, 0.6, 0.0]
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

  # A GRATE: the tile with every other bar of five pixels see-through, so half of it shows what is
  # behind, and the bars' edges fall on either half of a pair of the screen's pixels. A pair with no
  # see-through pixel is written whole, one that is all see-through is passed over, and only a pair
  # with one of each reads video memory back.
  SEE_THROUGH = 0x7C1F
  GRATE = TILE.each_with_index.map { |color, at| ((at % 64) / 5).odd? ? SEE_THROUGH : color }

  def test_a_grate_costs_under_twenty_cycles_a_pixel_without_perspective
    assert_fill_under(20, whole_screen_face(:none, see_through: SEE_THROUGH, data: GRATE), "a pixel at a time it cost 37")
  end

  def test_a_lit_grate_costs_under_thirty_two_cycles_a_pixel_without_perspective
    assert_fill_under(32, whole_screen_face(:none, see_through: SEE_THROUGH, data: GRATE, lit: true),
                      "a pixel at a time, its shade kept in memory, it cost 47")
  end

  # In perspective a picture with see-through pixels runs whole stretches together as one with none
  # does, each pair tested by two compares and a pair with a see-through pixel a call: a few
  # cycles a pixel over the solid face's. A stretch at a time, a call each, it cost twice that.
  def test_a_grate_leaning_away_costs_under_twenty_five_cycles_a_pixel_in_perspective_every_8_pixels
    assert_fill_under(25, whole_screen_face(:every_8_pixels, see_through: SEE_THROUGH, data: GRATE, far: 5.0),
                      "a stretch at a time it cost 61; a pixel at a time, 72")
  end

  def test_a_lit_grate_leaning_away_costs_under_thirty_seven_cycles_a_pixel_in_perspective_every_8_pixels
    assert_fill_under(37, whole_screen_face(:every_8_pixels, see_through: SEE_THROUGH, data: GRATE, far: 5.0, lit: true),
                      "a stretch at a time it cost 70")
  end

  # Every eight pixels the place on the picture is worked out exactly, and between it steps two
  # pixels at a time as without perspective. What a stretch costs on top of its pixels is most of
  # the difference: its picture's shifts are written into its instructions, and how far one over
  # the distance was moved stays in a register for the row.
  def test_a_face_leaning_away_costs_under_twenty_two_cycles_a_pixel_in_perspective_every_8_pixels
    assert_fill_under(22, whole_screen_face(:every_8_pixels, far: 5.0),
                      "a stretch at a time it cost 56; reading its shifts from memory, 24")
  end

  # Every sixteen pixels, the default: the second eight of each stretch go on stepping from where
  # the first stopped, and only the first works the place on the picture out.
  def test_a_face_leaning_away_costs_under_twenty_cycles_a_pixel_in_perspective_every_16_pixels
    assert_fill_under(20, whole_screen_face(:every_16_pixels, far: 5.0), "every 8 pixels it costs under 22")
  end

  def test_a_grate_leaning_away_costs_under_twenty_three_cycles_a_pixel_in_perspective_every_16_pixels
    assert_fill_under(23, whole_screen_face(:every_16_pixels, see_through: SEE_THROUGH, data: GRATE, far: 5.0),
                      "a stretch at a time it cost 39")
  end

  def test_a_lit_grate_leaning_away_costs_under_thirty_four_cycles_a_pixel_in_perspective_every_16_pixels
    assert_fill_under(34, whole_screen_face(:every_16_pixels, see_through: SEE_THROUGH, data: GRATE, far: 5.0, lit: true),
                      "a stretch at a time it cost 47")
  end

  def test_a_lit_face_leaning_away_costs_under_twenty_nine_cycles_a_pixel_in_perspective_every_16_pixels
    assert_fill_under(29, whole_screen_face(:every_16_pixels, far: 5.0, lit: true), "every 8 pixels it costs under 33")
  end

  def test_a_face_leaning_away_costs_under_ninety_cycles_a_pixel_in_perspective_every_pixel
    assert_fill_under(90, whole_screen_face(:every_pixel, far: 5.0), "a stretch at a time it cost 212")
  end

  # A lit pixel is its unlit cost and one more load, from the shading's table: about ten cycles
  # more, the table being read from the cartridge.
  def test_a_lit_face_costs_under_twenty_seven_cycles_a_pixel_without_perspective
    assert_fill_under(27, whole_screen_face(:none, lit: true), "unlit it costs under 17")
  end

  def test_a_lit_face_leaning_away_costs_under_thirty_three_cycles_a_pixel_in_perspective_every_8_pixels
    assert_fill_under(33, whole_screen_face(:every_8_pixels, far: 5.0, lit: true),
                      "a stretch at a time it cost 71; reading its shifts from memory, 34; unlit it costs under 22")
  end

  private def assert_fill_under(most, program, before)
    rom = assemble_rom(program, name: "FILLCOST")
    profile = VBlank::Diagnostics::Profiler.run(rom, frames: 60, picture: false)
    cycles = (1 - profile.idle_share) * CYCLES_A_SECOND / profile.fps / WHOLE_SCREEN

    assert_operator cycles, :<, most, "a pixel took #{cycles.round(1)} cycles; #{before}"
    assert_backends_agree(program, frames: 3, console_frames: 30, name: "FILLCOST")
  end
end
