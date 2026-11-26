# frozen_string_literal: true

require "test_helper"

# A rectangle whose far edge is past what a 32-bit number holds is cut to the screen, as the interpreter cuts it: the
# sum of its corner and its size is not worked out in 32 bits.
class TestFillRectEdges < Minitest::Test
  private def build(&block)
    builder = VBlank::Builder.new
    builder.instance_eval(&block)
    builder.finalize_program
    builder.program
  end

  def test_a_huge_width_is_cut_at_the_right_edge
    program = build do
      screen :bitmap
      clear_screen :blue
      left = var :left, 100
      wide = var :wide, 0x7fffffff
      fill_rect left, 10, wide, 5, Color.resolve(:red)
      halt
    end
    picture = game_player.run(program, frames: 2).screen

    assert_equal Color.resolve(:red), picture.pixel(100, 10)
    assert_equal Color.resolve(:red), picture.pixel(screen_width_of(program) - 1, 14)
    assert_equal Color.resolve(:blue), picture.pixel(99, 10)
  end

  def test_a_huge_height_is_cut_at_the_bottom_edge
    program = build do
      screen :bitmap
      clear_screen :blue
      top = var :top, 100
      tall = var :tall, 0x7fffffff
      fill_rect 10, top, 5, tall, Color.resolve(:red)
      halt
    end
    picture = game_player.run(program, frames: 2).screen

    assert_equal Color.resolve(:red), picture.pixel(10, 100)
    assert_equal Color.resolve(:blue), picture.pixel(10, 99)
  end

  private

  def screen_width_of(program) = program.described_console.screen_width
end
