#!/usr/bin/env ruby
# frozen_string_literal: true

# Sparks — a shower of particles: a fixed handful of slots, one spark spawned a frame at a
# random column, each falling until it leaves the bottom and hands its slot back.
#
# It is the shape a bullet, enemy or particle game spends its frame in: many of one thing,
# each with a few fields, walked every frame. They are an Array of Structs, which the game
# keeps as a pool: a fixed number of slots, walked oldest first. A spark that has fallen off
# the bottom is taken out, so a slot never leaks. On a bitmap screen nothing draws a spark on
# its own, so the walk draws each as a two-pixel dot.
#
# Run it to build examples/sparks.gba:
#   ruby examples/sparks.rb

require_relative "../lib/vblank"

module Sparks
  SLOTS = 32 # sparks alive at once; when all are up, the oldest makes room for the new one

  # One spark: where it is and how fast it falls. Its speed is 1 to 3, so a byte holds it.
  Spark = Struct.new(:x, :y, :vy) do
    narrow vy: :byte
  end

  # The game as a block the builder runs, so a test can drive the exact program that
  # ships — the headless interpreter runs THIS, the console runs the ROM.
  GAME = VBlank.game("SPARKS", consoles: %i[gba snes gbc]) do
    screen :bitmap
    seed 0x5EED # a fixed stream, so every run is the same run

    sparks = Array.new(capacity: SLOTS)

    game_loop do
      clear_screen :black
      # One new spark a frame, at a random column, falling at one of three speeds.
      sparks.shift if sparks.size == SLOTS
      sparks << Spark.new(rand(0..(screen_width - 2)), 0, rand(1..3))
      # One walk does it all: move each spark, draw it, and take it out once it is off the
      # bottom, which gives its slot back. The block's last line is the test `delete_if` asks.
      sparks.delete_if do |s|
        s.y += s.vy
        draw_rect_at s.x, s.y, 2, 2, :yellow
        s.y >= screen_height
      end
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Sparks::GAME.write_if_main
