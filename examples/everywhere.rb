#!/usr/bin/env ruby
# frozen_string_literal: true

# ONE GAME FILE FOR FOUR CONSOLES: the Game Boy Advance, the Game Boy Color, the Super Nintendo and
# the Sega Genesis. `ruby examples/everywhere.rb` builds a cartridge for each of them from the one
# block below.
#
# A ball bounces round the edges of the screen with a click at every wall, under the game's name,
# while a little tune plays.
#
# The four screens are four sizes, from the Color's 160×144 to the Genesis's 320×224. So the
# game never writes a number for one screen: every place comes from `screen_width` and
# `screen_height`, the size of the screen this build is for, read like any other Ruby number. That
# one habit is most of what fitting a game to several consoles takes, and there is ONE game loop.
#
# The rest is a choice the game makes while it is built, by asking `built_for?(:snes)`. It is a
# plain Ruby true or false, worked out once, before any of the game runs, so each console's
# cartridge holds only what that console was given:
#
#   - The Super Nintendo's title says SUPER BOUNCE, as its games liked to.
#   - The Super Nintendo's cartridge has no tune. A game whose music is long recordings might do
#     this, since a Super Nintendo keeps every sound it plays in 64 kilobytes of its own memory.
#     Here the tune is a few notes, and it is left out only to show how.
#
# The game as C, in a web page or as Ruby (`vblank run`) answers for the console it was built as,
# so all of them play the same game that console's cartridge does.

require_relative "../lib/vblank"

module Everywhere
  BALL = <<~ART
    ..####..
    .######.
    ########
    ########
    ########
    ########
    .######.
    ..####..
  ART
  BALL_SIZE = 8
  TITLE_ROW = 8 # how far down the title's letters are

  GAME = VBlank.game("EVERYWHERE", consoles: %i[gba gbc snes genesis]) do
    # A screen of tiles and sprites, with nothing behind the ball but a dark blue backdrop.
    screen :tiled, backdrop: rgb(0, 0, 8)
    enable_sound

    # --- What this console gets: two choices, made while the game is built ---
    super_nintendo = built_for?(:snes)
    title = super_nintendo ? "SUPER BOUNCE" : "BOUNCE"
    music = !super_nintendo

    define_sound :click, frequency: 660, duty: :quarter, decay: :fast
    if music
      song :tune do
        tempo 120
        note :C4, :eighth
        note :E4, :eighth
        note :G4, :quarter
        rest :quarter
      end
    end

    # --- Laid out from the screen this build is for ---
    right  = screen_width - BALL_SIZE  # the furthest right the ball's corner can go
    bottom = screen_height - BALL_SIZE # ...and the furthest down
    draw_text title, :center, TITLE_ROW, :yellow

    image(:ball, "#" => :white, "." => :transparent) { BALL }
    ball = sprite :ball, at: [screen_width / 2, screen_height / 2]
    x = var :x, screen_width / 2
    y = var :y, screen_height / 2
    dx = var :dx, 2 # how far it moves each pass, right and down
    dy = var :dy, 1

    game_loop do
      play_song :tune if music

      x += dx
      y += dy
      # At a wall the ball turns round: `abs!` sends it right or down, `negate_abs!` left or up.
      if x <= 0
        dx.abs!
        beep :click
      end
      if x >= right
        dx.negate_abs!
        beep :click
      end
      if y <= 0
        dy.abs!
        beep :click
      end
      if y >= bottom
        dy.negate_abs!
        beep :click
      end
      ball.move_to x, y
    end
  end

  def self.program(**kwargs) = GAME.program(**kwargs)
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Everywhere::GAME.write_if_main
