#!/usr/bin/env ruby
# frozen_string_literal: true

# Fonts — the same number drawn in two fonts, so you can see per-text font selection.
#
# draw_text / draw_number take a font: name from the Fonts registry. The score here
# is drawn once in the built-in 5x7 :default font and once in the compact 3x5 :tiny
# font — same value, visibly different size. A game reaches for :tiny when a HUD
# needs to pack numbers into a small corner. New fonts register the same way, and
# each carries its own metrics, so the framework sizes and costs text per font.
#
# Run it to build examples/fonts.gba:
#   ruby examples/fonts.rb

require_relative "../lib/vblank"

module FontsDemo
  SCORE = 12_345
  GAP = 3 # the pixels left clear between a label and the number under it

  GAME = VBlank.game("FONTS", consoles: %i[gba snes]) do
    screen :bitmap
    clear_screen :black

    # How far a number hangs below the top of its label. `text_height` is how tall a line of
    # a font comes out, so the number is spaced by what the letters measure, not by a figure
    # counted by eye; change the labels' font and the numbers keep their distance.
    below_label = text_height + GAP

    # The default 5x7 font.
    draw_text "DEFAULT", 8, 8, :white
    draw_number SCORE, 8, 8 + below_label, :green, digits: 5

    # The compact 3x5 :tiny font — the same number, half the height.
    draw_text "TINY", 8, 44, :white
    draw_number SCORE, 8, 44 + below_label, :green, digits: 5, font: :tiny

    halt
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

FontsDemo::GAME.write_if_main
