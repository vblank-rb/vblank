# frozen_string_literal: true

require "test_helper"
require "differential"

# A LONG LINE OF FIXED TEXT IN A GAME'S OWN BIG LETTERS. A short line is an instruction or two for
# each lit pixel, laid out in the code, and quick. In big letters that is most of a cartridge, so a
# line with many pixels keeps where they go in a table, and one routine stamps them.
class TestBigTextLines < Minitest::Test
  include Differential

  LETTERS = VBlank::Graphics::Fonts.default
  BIG_LINE = "88888"
  # An odd column, which the tear-free screen's two pixels to a halfword have to get right.
  COLUMN = 7

  # The built-in figures with every pixel made a 3 by 3 square.
  private def big_figures
    (0..9).to_h do |k|
      rows = Array.new(LETTERS.height * 3) { Array.new(LETTERS.width * 3, 0) }
      LETTERS.each_pixel(k.to_s) { |x, y| 9.times { |n| rows[(y * 3) + (n / 3)][(x * 3) + (n % 3)] = 1 } }
      [k.to_s, rows]
    end
  end

  private def plain_program(text: BIG_LINE, y: 9)
    glyphs = big_figures
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      font :big, glyphs: glyphs
      clear_screen :black
      draw_text text, COLUMN, y, :white, font: :big
      halt
    end
    b.finalize_program
    b.program
  end

  private def tear_free_program
    glyphs = big_figures
    b = Builder.new
    b.instance_eval do
      screen :bitmap, tear_free: true
      font :big, glyphs: glyphs
      game_loop do
        clear_screen :black
        draw_text BIG_LINE, COLUMN, 9, :white, font: :big
      end
    end
    b.finalize_program
    b.program
  end

  private def rom_size(program, name) = assemble_rom(program, name: name).size

  def setup
    require_emulator!
  end

  def test_a_big_line_on_the_plain_screen_is_every_pixel_the_interpreter_draws
    assert_backends_agree(plain_program, frames: 2, name: "BIGPLAIN")
  end

  def test_a_big_line_on_the_tear_free_screen_is_every_pixel_the_interpreter_draws
    assert_backends_agree(tear_free_program, frames: 4, name: "BIGPAGES")
  end

  def test_a_big_line_running_off_the_screen_keeps_what_is_on_it
    assert_backends_agree(plain_program(y: 150), frames: 2, name: "BIGEDGE")
  end

  # Two bytes of table for what was at least two instructions.
  def test_a_big_line_costs_about_two_bytes_a_pixel
    pixels_more = LETTERS.text_pixels("8" * 7) * 9

    grew = rom_size(plain_program(text: "8" * 12), "BIGLONG") - rom_size(plain_program, "BIGSHORT")

    assert_operator grew, :<, pixels_more * 3, "#{grew} bytes for #{pixels_more} pixels"
  end
end
