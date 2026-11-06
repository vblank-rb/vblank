# frozen_string_literal: true

require "test_helper"

# THE ADVANCE SHOWS EACH PIXEL OF A GAME OF BIG PIXELS AS A SQUARE OF FOUR
# (`screen :bitmap, pixel_size: 2`, Backends::GBA::Drawing#emit_bigger_pixels): read in the emulator,
# the whole 240×160 picture is the game's 120×80 one with every pixel doubled across and down, on a
# plain painted screen and a tear-free one.
class TestBiggerPixels < Minitest::Test
  # A game that paints a red dot in each corner of its small screen, and a green one at (31, 17),
  # over blue.
  private def rom(tear_free:)
    VBlank.game("BIGDOTS", consoles: %i[gba]) do
      screen :bitmap, tear_free: tear_free, pixel_size: 2
      right = screen_width - 1
      bottom = screen_height - 1
      game_loop do
        clear_screen :blue
        [[0, 0], [right, 0], [0, bottom], [right, bottom]].each { |x, y| pixel x, y, :red }
        pixel 31, 17, :green
      end
    end.build_rom(out: nil, err: nil, profile: false)
  end

  private def picture(tear_free:)
    require_emulator!
    VBlank::Diagnostics::Verifier.new(rom(tear_free: tear_free), frames: 12).frame_gba
  end

  private def at(picture, x, y) = picture[(y * 240) + x]

  def test_each_pixel_is_shown_as_a_square_of_four
    [false, true].each do |tear_free|
      shown = picture(tear_free: tear_free)
      red = Color.resolve(:red)
      green = Color.resolve(:green)
      blue = Color.resolve(:blue)

      [[0, 0], [238, 0], [0, 158], [238, 158]].each do |left, top|
        [[0, 0], [1, 0], [0, 1], [1, 1]].each do |dx, dy|
          assert_equal red, at(shown, left + dx, top + dy), "corner square at (#{left}, #{top}), tear_free #{tear_free}"
        end
      end
      [[62, 34], [63, 34], [62, 35], [63, 35]].each do |x, y|
        assert_equal green, at(shown, x, y), "the dot at (31, 17), tear_free #{tear_free}"
      end
      [[61, 34], [64, 34], [62, 33], [62, 36], [2, 0], [0, 2]].each do |x, y|
        assert_equal blue, at(shown, x, y), "beside a square at (#{x}, #{y}), tear_free #{tear_free}"
      end
    end
  end
end
