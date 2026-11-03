# frozen_string_literal: true

require "test_helper"

# Big sprite pictures beside small ones, on a tiled screen of the Genesis's, for the tests of what they
# cost the console's sprite table (test/lowering/genesis/vblank/ir/backends/genesis/test_genesis_sprite_pieces.rb).
module BigSpritePictureGames
  # A picture +width+ by +height+ in the list :art, every 8×8 square of it drawn but the ones +blank+ names
  # ([across, down] in squares). Each square is one colour, which goes red, green, blue along the row and
  # moves on two a row down, with its top left pixel white: a square shown in the wrong place, or turned,
  # shows as a colour or a white pixel where it does not belong.
  def self.picture(builder, name, width, height, blank: [])
    places = Array.new(width * height) do |at|
      x = at % width
      y = at / width
      next 0 if blank.include?([x / 8, y / 8])

      (x % 8).zero? && (y % 8).zero? ? 4 : 1 + (((x / 8) + ((y / 8) * 2)) % 3)
    end
    builder.image(name, width: width, height: height, colors: :art, places: places)
  end

  # A game showing a picture of 112×72 (+big+: :big or a turned one) and one of 64×64 side by side, and ten
  # small sprites on the same rows: drawn in 8×8 pieces, the three are more than the console's 80 entries,
  # and more than its 20 on a row.
  def self.game
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :genesis))
    builder.instance_eval do
      screen :tiled
      colors :art, %i[transparent red green blue white]
      # The top right corner of the big one, and each corner of the square, left blank.
      BigSpritePictureGames.picture(self, :big, 112, 72, blank: [[12, 0], [13, 0], [13, 1]])
      BigSpritePictureGames.picture(self, :square, 64, 64, blank: [[0, 0], [7, 0], [0, 7], [7, 7]])
      BigSpritePictureGames.picture(self, :dot, 8, 8)
      yield self if block_given?
      sprite :square, at: [128, 16]
      10.times { |i| sprite :dot, at: [200 + (i * 10), 40] }
      game_loop { nil }
    end
    builder.finalize_program
    builder.program
  end

  def self.big_game = game { |b| b.sprite :big, at: [8, 16] }

  def self.mirrored_game = game { |b| b.sprite b.mirror(:big), at: [8, 16] }
end

# A PICTURE BIGGER THAN ONE PIECE OF THE CONSOLE'S. A Genesis draws a sprite entry up to 32×32, and its
# table holds 80 entries, 20 on a row of the screen. Pictures this big take every piece they need only when
# the build covers each with the fewest big pieces, so every sprite here shows whole.
class TestBigSpritePicturesOnTheGenesis < Minitest::Test
  def test_two_big_pictures_and_ten_small_ones_show_whole
    screen = game_player.run(BigSpritePictureGames.big_game, frames: 4).screen

    assert_equal VBlank::Testing.shown(:white), screen.pixel(8, 16), "the big picture's first square"
    assert_equal VBlank::Testing.shown(:white), screen.pixel(8 + 104, 16 + 64), "its last"
    assert_equal VBlank::Testing.shown(:white), screen.pixel(128 + 56, 16 + 56 - 8), "the square's"
    assert_equal VBlank::Testing.shown(:white), screen.pixel(290, 40), "the last small one"
  end

  def test_a_mirrored_big_picture_shows_turned
    screen = game_player.run(BigSpritePictureGames.mirrored_game, frames: 4).screen

    assert_equal VBlank::Testing.shown(:white), screen.pixel(8 + 111, 16), "the first square, turned, has its white at its right"
    assert_equal 0, screen.pixel(8, 16), "the blank corner is at the left now"
  end
end
