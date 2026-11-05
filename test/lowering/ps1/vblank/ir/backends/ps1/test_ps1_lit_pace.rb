# frozen_string_literal: true

require "test_helper"
require "stringio"

# What lighting a place costs on the PlayStation, measured in Beetle PSX (Diagnostics::PS1Profiler). A
# game of the console's day lit its walls with a shading of many levels, its own fade tables, and light
# that fell off steeply down a corridor; the chip shaded each triangle itself (PS1::FacePieces), so a
# wall crossing most of the levels cost about what it cost unlit.
class TestPS1LitPace < Minitest::Test
  # Thirty-two levels: level 31 is each colour as it is, each level below a thirty-second darker.
  LEVELS = 32

  # The pictures' colours, red, green and blue from 0 to 31: the stone's mortar and blocks.
  COLORS = Ractor.make_shareable([[8, 8, 9], [20, 20, 22]])

  # Each picture colour at every level, brightest first: colour +color+ at level +level+ is at place
  # color * LEVELS + (LEVELS - 1 - level).
  SHADES = Ractor.make_shareable(COLORS.flat_map do |red, green, blue|
    (0...LEVELS).map { |dark| [red, green, blue].map { |part| part * (LEVELS - dark) / LEVELS } }
  end)

  # For each level, where each of the shading's colours goes: a picture colour to itself at that level.
  SHADE_LEVELS = Ractor.make_shareable((0...LEVELS).map do |level|
    (0...SHADES.length).map { |place| (place % LEVELS).zero? ? place + (LEVELS - 1 - level) : place }
  end)

  BLOCKS = <<~ART
    ########
    #......#
    #......#
    ########
    ###.....
    ###.....
    ###.....
    ########
  ART

  WHOLE = Ractor.make_shareable([[0, 0], [8, 0], [8, 8], [0, 8]])
  # A ring of the corridor, top left first and round to the right.
  RING_CORNERS = Ractor.make_shareable([[-1.0, 1.0], [1.0, 1.0], [1.0, -1.0], [-1.0, -1.0]])

  # A corridor three rooms deep, each wall lit from full at its near end to an eighth at its far one, so
  # each crosses 28 of the 32 levels, drawn in perspective over the whole screen; lit unless a build
  # says `lit: false`.
  CORRIDOR = VBlank.game("LIT ROOMS", consoles: %i[ps1]) do
    screen :bitmap, tear_free: true
    lit = setting :lit, true
    image(:stone, "#" => rgb(*COLORS[0]), "." => rgb(*COLORS[1])) { BLOCKS }
    shading :fade, colors: SHADES.map { |red, green, blue| rgb(red, green, blue) }, levels: SHADE_LEVELS
    place :rooms, shading: :fade do
      rings = [0.0, 2.0, 4.0, 6.0].map { |z| RING_CORNERS.map { |x, y| point(x, y, z) } }
      rings.each_cons(2) do |near, far|
        light = [1.0, 0.125, 0.125, 1.0]
        face near[0], far[0], far[3], near[3], picture: :stone, on_picture: WHOLE, light: light
        face far[1], near[1], near[2], far[2], picture: :stone, on_picture: WHOLE, light: light.rotate(1)
        face near[3], far[3], far[2], near[2], picture: :stone, on_picture: WHOLE, light: light
        face near[0], near[1], far[1], far[0], picture: :stone, on_picture: WHOLE, light: [1.0, 1.0, 0.125, 0.125]
      end
    end
    eye = viewer :eye, at: [0.0, 0.0, 0.1]
    phase = var :phase, 0
    game_loop do
      if phase < 8
        eye.turn :left, by: 1
      else
        eye.turn :right, by: 1
      end
      phase += 1
      phase = 0 if phase == 16
      clear_screen :black
      draw_place :rooms, seen_by: eye, lit: lit
    end
  end

  # Lit, a pass takes the frames it takes unlit, and the processor's time grows by no more than the
  # chip's own shading of the triangles costs: under 28% again.
  def test_lighting_a_wall_across_28_levels_costs_under_28_percent_again
    lit = profile
    unlit = profile(lit: false)

    assert_equal unlit.passes_by_frames, lit.passes_by_frames
    assert_operator busy_frames(lit), :<, busy_frames(unlit) * 1.28, "lit #{busy_frames(lit)}, unlit #{busy_frames(unlit)}"
  end

  # How much of a frame the processor was at work for, a pass.
  private def busy_frames(result) = (1 - result.idle_share) * result.frames / result.passes

  private def profile(**settings)
    rom = CORRIDOR.build_rom(console: :ps1, settings: settings, out: StringIO.new, err: StringIO.new, profile: false)
    rom.profile(out: StringIO.new, frames: 16)
  end
end
