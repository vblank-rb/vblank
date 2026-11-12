# frozen_string_literal: true

require "test_helper"

# A background of more colours than the other consoles' tiles hold, on every run that plays games as the
# PlayStation. Its graphics chip draws a background as a picture through a colour table of 16 or 256
# entries, or in the colours themselves past that (Backends::PS1::PlaneColors), so every colour shows.
class TestTiledBackgroundColoursOnThePlayStation < Minitest::Test
  # Fifteen colours a tile: three tiles are 45 colours in all, and twenty 300.
  def test_a_background_of_many_colours_shows_each
    [3, 20].each do |count|
      screen = game_player.run(many_colours_program(count), frames: 2).screen

      count.times do |tile|
        assert_equal [many_colour(tile, 0), many_colour(tile, 14)], [screen.pixel(tile * 8, 0), screen.pixel((tile * 8) + 6, 1)],
                     "tile #{tile} of #{count}"
      end
    end
  end

  MANY_COLOUR_KEYS = "abcdefghijklmno"

  # The colour of place +key+ of tile +tile+, for the game block to read: each tile fifteen of its own.
  def many_colour(tile, key) = 0x0421 + (tile * 15) + key

  # +count+ tiles side by side, each its fifteen colours one after another, a key a pixel.
  private def many_colours_program(count)
    keys = MANY_COLOUR_KEYS
    test = self
    b = Builder.new
    b.instance_eval do
      screen :tiled
      count.times do |tile|
        art = Array.new(8) { |row| Array.new(8) { |col| keys[((row * 8) + col) % keys.length] }.join }.join("\n")
        image(:"many_#{tile}", keys.chars.each_with_index.to_h { |key, at| [key, test.many_colour(tile, at)] }) { art }
      end
      tiles :many, (0...count).to_h { |tile| [(65 + tile).chr, :"many_#{tile}"] }
      background :board, tiles: :many, map: (0...count).map { |tile| (65 + tile).chr }.join
      passes = var :passes, 0
      game_loop { passes += 1 }
    end
    b.finalize_program
    b.program
  end
end
