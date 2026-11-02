#!/usr/bin/env ruby
# frozen_string_literal: true

# Flowers — a field that sways, with a map that never changes.
#
# It shows what `tile_pictures` is for. A flower is one tile on the map however many times it
# appears, and it has three pictures in the cartridge, so one word changes every flower in the field
# on the next frame, for the cost of one picture. Telling each cell a new tile would cost a write
# for every flower.
#
# Run it to build examples/flowers.gba:
#   ruby examples/flowers.rb

require_relative "../lib/vblank"

module Flowers
  FRAMES_A_PICTURE = 12 # how long the flowers lean each way

  # Each character is a place in the colours below: `.` the first after see-through, and so on.
  PLACES = { "." => 1, "#" => 2, "o" => 3 }.freeze

  UPRIGHT = ["...oo...", "..oooo..", "...oo...", "...##...", "...##...", "..###...", "...##...", "...##..."].freeze
  LEFT = ["..oo....", ".oooo...", "..oo....", "...#....", "...##...", "..###...", "...##...", "...##..."].freeze
  RIGHT = ["....oo..", "...oooo.", "....oo..", "....#...", "...##...", "..###...", "...##...", "...##..."].freeze

  def self.places(rows) = rows.join.chars.map { |char| PLACES.fetch(char) }

  # The game as a block the builder runs, so a test can drive the exact program that ships.
  GAME = VBlank.game("FLOWERS", consoles: %i[gba gbc snes]) do
    screen :tiled
    colors :meadow, [:transparent, :green, rgb(4, 16, 4), :yellow]

    image :upright, width: 8, height: 8, colors: :meadow, places: Flowers.places(UPRIGHT)
    image :left, width: 8, height: 8, colors: :meadow, places: Flowers.places(LEFT)
    image :right, width: 8, height: 8, colors: :meadow, places: Flowers.places(RIGHT)
    image :grass, width: 8, height: 8, colors: :meadow, places: Array.new(64, 1)

    field = tile_pictures :field, colors: :meadow, tiles: { flower: %i[upright left upright right] }
    tiles :meadow_tiles, "f" => field[:flower], "." => :grass

    # A flower in every other cell of every other row.
    across = screen_width / 8
    down = screen_height / 8
    background :ground, tiles: :meadow_tiles,
                        map: Array.new(down) { |row| Array.new(across) { |col| row.even? && col.even? ? "f" : "." }.join }

    passes = var :passes, 0
    game_loop do
      passes += 1
      field.show((passes / FRAMES_A_PICTURE) % 4)
    end
  end

  def self.program = GAME.program
  def self.build_rom(**kwargs) = GAME.build_rom(**kwargs)
end

Flowers::GAME.write_if_main
