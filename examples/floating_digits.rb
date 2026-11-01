#!/usr/bin/env ruby
# frozen_string_literal: true

# Floating digits — the numbers 0 through 9 drift around the screen and bounce off
# the walls, each in its own solid color.
#
# It's also a little study in "moving text". A number that STAYS PUT and only
# changes value (a score, a timer) is what draw_number is for. But a number whose
# POSITION moves is a different job: it has to be picked up and set down each frame
# without smearing a trail — the same problem a moving sprite has. draw_text and
# draw_number draw at a FIXED spot, so they can't move; the one draw verb with a
# run-time position is `blit`. So each digit here is a tiny glyph image (drawn from
# the built-in font) that we blit at a moving position — a moving object, built by
# hand. When the `sprite` helper lands, this whole file collapses to "make a sprite
# for each digit and nudge it"; for now it's the honest manual version.
#
# It is manual about time as well. A `game_loop` normally waits for the screen by itself
# at the top of every pass. `frame_sync: :manual` takes that away, and `wait_vblank` is
# the wait written out: it holds the game until the console has finished drawing a
# picture, which is the moment it is safe to start on the next one. Leave it out and the
# game runs flat out, drawing over a screen that is still being shown.
#
# Run it to build examples/floating_digits.gba:
#   ruby examples/floating_digits.rb

require_relative "../lib/vblank"

module FloatingDigits
  W = VBlank::Graphics::Fonts.default.width  # 5px wide glyph
  H = VBlank::Graphics::Fonts.default.height # 7px tall glyph

  # One solid color per digit (5-bit R,G,B channels, 0..31), all clearly distinct.
  COLORS = Ractor.make_shareable([
    [31,  0,  0], [0, 31,  0], [8, 12, 31], [31, 31,  0], [0, 31, 31],
    [31,  0, 31], [31, 31, 31], [31, 18,  0], [18, 31,  0], [0, 18, 31],
  ])

  # The glyph for digit +d+ as ASCII art ('#' = a lit pixel, '.' = transparent),
  # read straight from the built-in bitmap font — so we don't hand-draw ten digits.
  def self.glyph_art(d)
    lit = {}
    VBlank::Graphics::Fonts.default.each_pixel(d.to_s) { |x, y| lit[[x, y]] = true }
    (0...H).map { |y| (0...W).map { |x| lit[[x, y]] ? "#" : "." }.join }.join("\n")
  end

  # The game as a block the builder runs (so a test can drive the exact program
  # that ships — the interpreter runs THIS, the console runs the ROM built from it).
  GAME = VBlank.game("FLOATNUM", consoles: %i[gba snes], frame_sync: :manual) do
    screen :bitmap

    # A colored glyph image per digit. '.' is transparent, so only the digit's lit
    # pixels are drawn and the black field shows through the rest of the 5x7 box.
    10.times do |d|
      image(:"digit#{d}", "." => :transparent, "#" => rgb(*COLORS[d])) { FloatingDigits.glyph_art(d) }
    end

    # Each digit gets a position and a velocity. They start spread across the
    # screen, each drifting a little differently.
    movers = 10.times.map do |d|
      {
        d: d,
        x:  var(:"x#{d}",  10 + (d % 5) * 44),
        y:  var(:"y#{d}",  22 + (d / 5) * 74),
        dx: var(:"dx#{d}", [2, -2, 1, -1, 2][d % 5]),
        dy: var(:"dy#{d}", [1, 2, -1, -2, 1][(d + 2) % 5]),
      }
    end

    max_x = screen_width - W # rightmost x that keeps the whole glyph on screen
    max_y = screen_height - H

    game_loop do
      wait_vblank # one picture a frame: this is the line the game loop would have added

      # The simple, unclever way: wipe the screen and redraw every digit. It's a
      # touch wasteful (a real game would erase only where each digit was), but at
      # this scale it fits the frame comfortably and keeps the example plain.
      clear_screen :black

      movers.each do |m|
        dx = m[:dx]
        dy = m[:dy]

        m[:x] += dx
        m[:y] += dy

        # Bounce off each wall: pin the digit to the edge and reverse its direction.
        if m[:x] < 0
          m[:x] = 0
          dx.flip!
        end
        if m[:x] > max_x
          m[:x] = max_x
          dx.flip!
        end
        if m[:y] < 0
          m[:y] = 0
          dy.flip!
        end
        if m[:y] > max_y
          m[:y] = max_y
          dy.flip!
        end

        blit :"digit#{m[:d]}", :"x#{m[:d]}", :"y#{m[:d]}"
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

FloatingDigits::GAME.write_if_main
