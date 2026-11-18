#!/usr/bin/env ruby
# frozen_string_literal: true

# A PICTURE WIDER THAN THE SCREEN, shown whole where it fits and panned across where it does not.
# `ruby examples/panorama.rb` builds the Advance's cartridge; `vblank build examples/panorama.rb
# --format=web` (or native, or ruby) builds the same file for a computer.
#
# The picture is 320×200: a sky with a sun, the ground, and a post at each edge, red on the left
# and blue on the right, so you can tell when you see all of it.
#
# The game asks for a screen that size with `screen :bitmap, size: [320, 200]`. A computer's build
# (the desktop program, the web page, the Ruby file) gives it, and the window opens that size. A
# console cannot change its screen, so the Advance's cartridge keeps its 240×160 and nothing is
# refused. `screen_width` and `screen_height` say which the build gave, as plain Ruby numbers
# while the game is built, so the game asks "does the picture fit?" once, and each build holds
# only the half of the answer it uses. Nothing in the game asks which machine it is on.

require_relative "../lib/vblank"

module Panorama
  WIDTH = 320
  HEIGHT = 200
  POST = 8         # how wide each edge's post is
  HORIZON = 130    # the first row of ground
  SUN_X = 160      # the middle of the sun
  SUN_Y = 60
  SUN_RADIUS = 20

  # The colour of the picture at (+x+, +y+).
  def self.color_at(x, y)
    return :red if x < POST
    return :blue if x >= WIDTH - POST
    return :yellow if ((x - SUN_X)**2) + ((y - SUN_Y)**2) < SUN_RADIUS**2

    y < HORIZON ? :cyan : :green
  end

  # The picture's colours, row by row.
  def self.pixels = Array.new(WIDTH * HEIGHT) { |at| color_at(at % WIDTH, at / WIDTH) }

  GAME = VBlank.game("PANORAMA", consoles: %i[gba]) do
    # The screen this game would like. Where the build cannot give it, it gives its own.
    screen :bitmap, size: [WIDTH, HEIGHT]
    image :view, width: WIDTH, height: HEIGHT, data: Panorama.pixels

    if screen_width >= WIDTH && screen_height >= HEIGHT
      # It fits: draw it once, in the middle of whatever screen this is.
      blit :view, (screen_width - WIDTH) / 2, (screen_height - HEIGHT) / 2
      game_loop {} # nothing moves; the loop keeps the picture up
    else
      # It does not: show the middle rows, and walk the screen from the picture's left edge to its
      # right and back, a pixel a pass. Drawing at a place left of the screen's edge shows the part
      # of the picture to the right of it; what falls off the screen is not drawn.
      farthest = WIDTH - screen_width
      top = (screen_height - HEIGHT) / 2
      pan = 0  # how far the screen is from the picture's left edge
      step = 1 # and which way it is going
      game_loop do
        blit :view, -pan, top
        pan += step
        step = -1 if pan >= farthest
        step = 1 if pan <= 0
      end
    end
  end

  def self.program(**kwargs) = GAME.program(**kwargs)
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Panorama::GAME.write_if_main
