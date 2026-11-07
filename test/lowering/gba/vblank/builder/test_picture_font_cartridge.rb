# frozen_string_literal: true

require "test_helper"
require "all/vblank/builder/test_picture_font"

# A font of the game's own pictures on the Advance's cartridge: a live number read back in the
# emulator, and what its code costs. What every run draws is in
# test/all/vblank/builder/test_picture_font.rb.
class TestPictureFontCartridge < Minitest::Test
  NUMERALS = ("0".."9").map { |digit| :"numeral_#{digit}" }.freeze

  # A game with the numerals whose loop runs +draw+ (given the score) before each wait.
  private def numerals_game(&draw)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clear_screen :black
      TestPictureFont.declare_numerals(self)
      score = var :score, 407
      game_loop do
        draw&.call(self, score)
        wait_vblank
      end
    end
    b.finalize_program
    b.program
  end

  private def emitted(&draw) = GBA.new.lower(numerals_game(&draw)).bytesize

  # +count+ five-digit numbers, in the numerals or (+color+ given) in the built-in font.
  private def numbers(count, color: nil)
    lambda do |game, score|
      count.times do |row|
        if color
          game.draw_number score, 20, 30 + (row * 10), color, digits: 5
        else
          game.draw_number score, 20, 30 + (row * 10), digits: 5, font: :numerals
        end
      end
    end
  end

  def test_a_live_number_in_numerals_shows_on_the_cartridge
    rom = ROM.assemble(GBA.new.lower(numerals_game(&numbers(1))), title: "PICFONT", code: "BPFN", maker: "01")
    v = assert_emulator_loads_rom(rom, frames: 4)
    [["4", 28], ["0", 32], ["7", 36]].each do |digit, x|
      want = TestPictureFont.numeral_pixels(digit).map { |name| Color.resolve(name) }
      got = (0...3).flat_map { |dy| (0...4).map { |dx| v.pixel_gba(x + dx, 30 + dy) } }
      assert_equal want, got, "the numeral #{digit} at column #{x}"
    end
  end

  # A digit place draws one of ten pictures, which is a test and a copy for each. Written out at
  # every place that is most of a cartridge's code, so the font's places call one routine that
  # does it, written once: the first number costs about one place written out, and each further
  # number less than a number in the built-in font.
  def test_a_number_in_numerals_draws_its_places_through_one_routine
    none = emitted
    first = emitted(&numbers(1)) - none
    second = emitted(&numbers(2)) - emitted(&numbers(1))
    built_in = emitted(&numbers(1, color: :white)) - none
    one_place = emitted { |game, score| game.blit NUMERALS, 20, 30, showing: score } - none

    assert_operator first, :<, 2 * one_place, "five places, one routine"
    assert_operator second, :<, built_in, "a second number in the numerals"
  end
end
