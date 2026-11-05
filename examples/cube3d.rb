#!/usr/bin/env ruby
# frozen_string_literal: true

# Cube 3D — a wooden crate floating in space, and you fly round it.
#
# The raycaster draws a maze from a flat grid, and its walls only ever stand upright. This draws
# a real 3D thing instead: a PLACE made of flat FACES, each joining four POINTS in space, each
# with a PICTURE on it. You are a VIEWER: a spot in space and three arrows saying which way is
# right, which way is up and which way is ahead. Every frame the framework turns each point to
# the viewer, works out where it lands on the screen (a point twice as far away lands half as far
# from the middle), cuts away whatever is behind you, and fills each face with its picture.
#
# Fly with A (ahead) and B (back). Turn with LEFT and RIGHT, tip up and down with UP and DOWN,
# and roll with L and R. Build it:
#   ruby examples/cube3d.rb
#
# Three things worth noticing:
#
# - A face is seen from its front only: the side from which its corners go round clockwise. Fly
#   inside the crate and it vanishes, because you see every face from behind. (`both_sides: true`
#   on `draw_place` draws the backs too.)
# - A picture repeats like wallpaper past its edges, so the lid shows the crate's boards four
#   times by asking for corners twice as far across the picture.
# - Every turn keeps the viewer's arrows square and of length one, so you can fly for as long as
#   you like and the crate never comes out stretched.

require_relative "../lib/vblank"

module Cube3D
  # The crate's boards, 16 by 16: a frame round the edge and a brace across the middle.
  CRATE = <<~ART
    ################
    #..............#
    #.oooooooooooo.#
    #.o..........o.#
    #.o.oooooooo.o.#
    #.o.o......o.o.#
    #.o.o......o.o.#
    #.o.o......o.o.#
    #.o.o......o.o.#
    #.o.o......o.o.#
    #.o.o......o.o.#
    #.o.oooooooo.o.#
    #.o..........o.#
    #.oooooooooooo.#
    #..............#
    ################
  ART

  # The four corners of a whole picture, top left first and round to the right.
  WHOLE = Ractor.make_shareable([[0, 0], [16, 0], [16, 16], [0, 16]])
  # ...and the same reaching twice as far, so the picture repeats twice each way.
  TWICE = Ractor.make_shareable([[0, 0], [32, 0], [32, 32], [0, 32]])

  GAME = VBlank.game("CUBE3D", consoles: %i[gba ps1]) do
    screen :bitmap, tear_free: true
    image :crate, "#" => rgb(12, 6, 2), "." => rgb(24, 14, 6), "o" => rgb(30, 22, 10) do
      CRATE
    end
    image :lid, "#" => rgb(10, 10, 10), "." => rgb(26, 26, 24), "o" => rgb(18, 18, 18) do
      CRATE
    end

    place :crate do
      # The eight corners of a cube two wholes across, centred on nothing at all.
      a = point(-1.0, 1.0, -1.0)
      b = point(1.0, 1.0, -1.0)
      c = point(1.0, -1.0, -1.0)
      d = point(-1.0, -1.0, -1.0)
      e = point(-1.0, 1.0, 1.0)
      f = point(1.0, 1.0, 1.0)
      g = point(1.0, -1.0, 1.0)
      h = point(-1.0, -1.0, 1.0)

      # Each face's corners go round clockwise as seen from outside the cube.
      face a, b, c, d, picture: :crate, on_picture: WHOLE # the near side
      face f, e, h, g, picture: :crate, on_picture: WHOLE # the far side
      face e, a, d, h, picture: :crate, on_picture: WHOLE # the left side
      face b, f, g, c, picture: :crate, on_picture: WHOLE # the right side
      face e, f, b, a, picture: :lid, on_picture: TWICE   # the top
      face g, h, d, c, picture: :lid, on_picture: TWICE   # the bottom
    end

    # Four wholes in front of the crate, looking at it.
    eye = viewer :eye, at: [0.0, 0.0, -4.0]

    game_loop do
      eye.turn :left, by: 2 if held(:left)
      eye.turn :right, by: 2 if held(:right)
      eye.turn :up, by: 2 if held(:up)
      eye.turn :down, by: 2 if held(:down)
      eye.roll :left, by: 2 if held(:l)
      eye.roll :right, by: 2 if held(:r)
      eye.move :ahead, by: 0.05 if held(:a)
      eye.move :back, by: 0.05 if held(:b)

      clear_screen rgb(2, 2, 10) # space round the crate
      draw_place :crate, seen_by: eye
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Cube3D::GAME.write_if_main
