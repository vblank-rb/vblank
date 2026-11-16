# frozen_string_literal: true

require_relative "test_helper"

# Core.picture_colors on pictures no cartridge would draw: every pixel a different random colour,
# so a pixel read from the wrong place, or a colour worked out wrongly, cannot hide behind a
# neighbour of the same colour. The answer is worked out here a pixel at a time from the bytes:
# the top-left pixel of each square bsnes drew, its red, green and blue cut to five bits each.
class TestPictureColors < Minitest::Test
  def test_a_picture_drawn_at_twice_the_size_takes_each_squares_top_left_pixel
    assert_converted_like_by_hand(512, 448)
  end

  def test_a_picture_drawn_at_the_consoles_size_takes_every_pixel
    assert_converted_like_by_hand(256, 224)
  end

  private def assert_converted_like_by_hand(drawn_width, drawn_height)
    buffer = Random.new(drawn_width).bytes(drawn_width * drawn_height * 4)
    across = drawn_width / RubySNESEmulator::Core::WIDTH
    down = drawn_height / RubySNESEmulator::Core::HEIGHT
    expected = (0...RubySNESEmulator::Core::HEIGHT).flat_map do |y|
      (0...RubySNESEmulator::Core::WIDTH).map do |x|
        at = ((y * down * drawn_width) + (x * across)) * 4
        blue, green, red = buffer.byteslice(at, 3).bytes
        (red >> 3) | ((green >> 3) << 5) | ((blue >> 3) << 10)
      end
    end

    assert_equal expected, RubySNESEmulator::Core.picture_colors(buffer, drawn_width, drawn_height)
  end
end
