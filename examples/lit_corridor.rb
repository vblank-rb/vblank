#!/usr/bin/env ruby
# frozen_string_literal: true

# Lit Corridor — a stone corridor lit by one lamp hanging from its ceiling, and the lamp flickers.
#
# Every corner of every face has its own light, from nought (black) to one (the picture's own
# colours), and the light is blended smoothly across each face. The game gives the colours each
# light makes as a SHADING: for each level of light, darkest first, which colour each of the
# picture's colours becomes. Here a level is one eighth darker than the next.
#
# The light each corner gets is worked out once, from how far it is from the lamp. The lamp's
# flicker is light the game adds to the points round it as it runs (`point_lights`): one pass in
# four or so it rolls a number, and the lamp dims by that much.
#
# Fly with A (ahead) and B (back), turn with LEFT and RIGHT.
# Build it:
#   ruby examples/lit_corridor.rb

require_relative "../lib/vblank"

module LitCorridor
  # A wall picture 16 by 16 pixels: blocks with a line of mortar round each.
  BLOCKS = <<~ART
    ################
    #......##......#
    #......##......#
    #......##......#
    #......##......#
    #......##......#
    #......##......#
    ################
    ################
    ###......##.....
    ###......##.....
    ###......##.....
    ###......##.....
    ###......##.....
    ###......##.....
    ################
  ART

  # The four corners of a whole picture, top left first and round to the right.
  WHOLE = Ractor.make_shareable([[0, 0], [16, 0], [16, 16], [0, 16]])

  # The pictures' colours, each as red, green and blue from 0 to 31: the stone's mortar and blocks,
  # and the floor's.
  COLORS = Ractor.make_shareable([[8, 8, 9], [20, 20, 22], [10, 6, 3], [18, 12, 6]])

  # Eight levels of light. Level 7 is each colour as it is; each level below is an eighth darker.
  LEVELS = 8

  # The shading's colours: each picture colour at every level, brightest first, so colour
  # +color+ at level +level+ is at place color * LEVELS + (LEVELS - 1 - level).
  SHADES = Ractor.make_shareable(COLORS.flat_map do |red, green, blue|
    (0...LEVELS).map { |dark| [red, green, blue].map { |part| part * (LEVELS - dark) / LEVELS } }
  end)

  # For each level, the place of the colour each of the shading's colours becomes: a picture colour
  # becomes itself darkened to that level, and a darkened one (no picture has it) stays as it is.
  SHADE_LEVELS = Ractor.make_shareable((0...LEVELS).map do |level|
    (0...SHADES.length).map { |place| (place % LEVELS).zero? ? place + (LEVELS - 1 - level) : place }
  end)

  # The corridor's sections: a ring of four points every two wholes ahead, from just behind you to
  # the end wall. The lamp hangs over the middle ring.
  RINGS = Ractor.make_shareable([0.0, 2.0, 4.0, 6.0, 8.0, 10.0])
  RING_CORNERS = Ractor.make_shareable([[-1.0, 1.0], [1.0, 1.0], [1.0, -1.0], [-1.0, -1.0]])
  LAMP = 3

  # How lit a point is: full under the lamp, less with each whole away, never quite dark.
  def self.light_at(ring) = (1.0 - ((ring - LAMP).abs * 0.22)).clamp(0.12, 1.0)

  GAME = VBlank.game("LIT CORRIDOR", consoles: %i[gba ps1]) do
    screen :bitmap, tear_free: true
    # Drawn lit unless a build says `lit: false`, to see what the light costs.
    lit = setting :lit, true
    stone_rgb = COLORS[0..1].map { |red, green, blue| rgb(red, green, blue) }
    ground_rgb = COLORS[2..3].map { |red, green, blue| rgb(red, green, blue) }
    image(:stone, "#" => stone_rgb[0], "." => stone_rgb[1]) { BLOCKS }
    image(:ground, "#" => ground_rgb[0], "." => ground_rgb[1]) { BLOCKS }
    shading :lamplight, colors: SHADES.map { |red, green, blue| rgb(red, green, blue) }, levels: SHADE_LEVELS

    lamp_points = []
    corridor = place :corridor, shading: :lamplight do
      # Each ring's points: top left, top right, bottom right, bottom left.
      rings = RINGS.map do |z|
        RING_CORNERS.map { |x, y| point(x, y, z) }
      end
      lamp_points.concat(rings[LAMP])
      rings.each_cons(2).with_index do |(near, far), ring|
        lit = [LitCorridor.light_at(ring), LitCorridor.light_at(ring + 1)]
        # Seen from inside, each face's points go round clockwise.
        face near[0], far[0], far[3], near[3], picture: :stone, on_picture: WHOLE, light: [lit[0], lit[1], lit[1], lit[0]]
        face far[1], near[1], near[2], far[2], picture: :stone, on_picture: WHOLE, light: [lit[1], lit[0], lit[0], lit[1]]
        face near[3], far[3], far[2], near[2], picture: :ground, on_picture: WHOLE, light: [lit[0], lit[1], lit[1], lit[0]]
        face near[0], near[1], far[1], far[0], picture: :stone, on_picture: WHOLE, light: [lit[0], lit[0], lit[1], lit[1]]
      end
      last = rings.last
      face last[0], last[1], last[2], last[3], picture: :stone, on_picture: WHOLE,
                                               light: LitCorridor.light_at(RINGS.length - 1)
    end

    eye = viewer :eye, at: [0.0, 0.0, 0.0]

    # How far the lamp is dimmed this moment, in steps of a tenth.
    flicker = var :flicker, 0

    game_loop do
      eye.turn :left, by: 2 if held(:left)
      eye.turn :right, by: 2 if held(:right)
      eye.move :ahead, by: 0.05 if held(:a)
      eye.move :back, by: 0.05 if held(:b)

      roll :flicker, 0..4 if chance(25)
      lamp_points.each { |point| corridor.point_lights[point] = flicker * -0.1 }

      clear_screen :black
      draw_place :corridor, seen_by: eye, lit: lit
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

LitCorridor::GAME.write_if_main
