# frozen_string_literal: true

require "test_helper"
require "web_page"

# The page shows the game in whole-number pixels (runtime/rg_mount.js, fit_whole_pixels): each pixel
# of the console's picture is the same whole number of the screen's own pixels, on a plain screen,
# a Retina one and a laptop at 125% or 150%. The tests assert the sizes the page sets on the canvas,
# worked out by hand beside each; the canvas is 240 by 160 pixels.
class TestJSPagePixels < Minitest::Test
  include WebPage

  # The width and height the page set on its screen, as "width=720px height=480px".
  private def style_of(lines) = lines.grep(/\Astyle screen /).map { |line| line[/width=\S+ height=\S+/] }

  private def sizes_for(steps, ratio:, box:)
    style_of(played_page(steps, walking_game, browser: ["device-pixel-ratio:#{ratio}", "canvas-box:#{box}"]))
  end

  def test_a_plain_screen_shows_three_times_over
    # 720 / 240 = 3 whole pixels each, 480 / 160 = 3.
    assert_equal ["width=720px height=480px"], sizes_for(["style screen"], ratio: 1, box: "720x480")
  end

  def test_a_retina_screen_shows_six_of_its_pixels_a_pixel
    # 720 x 2 = 1440 screen pixels, six whole 240s; six of them are 720 layout pixels again.
    assert_equal ["width=720px height=480px"], sizes_for(["style screen"], ratio: 2, box: "720x480")
  end

  def test_a_screen_at_150_percent_rounds_down_to_four_of_its_pixels
    # 720 x 1.5 = 1080 screen pixels, four whole 240s (960): 960 / 1.5 = 640 wide, 4 x 160 / 1.5 = 426.67 tall.
    assert_equal ["width=640px height=426.6666666666667px"], sizes_for(["style screen"], ratio: 1.5, box: "720x480")
  end

  def test_a_screen_at_125_percent_rounds_down_to_two_of_its_pixels
    # 500 x 1.25 = 625 screen pixels, two whole 240s (480): 480 / 1.25 = 384 wide, 2 x 160 / 1.25 = 256 tall.
    assert_equal ["width=384px height=256px"], sizes_for(["style screen"], ratio: 1.25, box: "500x333")
  end

  def test_a_room_too_small_for_one_whole_multiple_keeps_the_page_layout
    # 720 / 240 = 3 whole pixels each; narrowed to 200, less than one 240, the page sets no size.
    assert_equal ["width=720px height=480px", "width=- height=-"],
                 sizes_for(["style screen", "resize 200x133", "style screen"], ratio: 1, box: "720x480")
  end

  def test_a_resize_fits_the_picture_again
    # 1000 / 240 = 4 whole pixels, 960 wide and 640 tall; at ratio 2, 2000 / 240 = 8 whole, 8 x 240 / 2 = 960.
    assert_equal ["width=960px height=640px", "width=960px height=640px"],
                 sizes_for(["resize 1000x667", "style screen", "resize 1000x667 2", "style screen"], ratio: 1, box: "720x480")
  end

  def test_full_screen_leaves_the_size_to_the_browser
    # 1080 screen pixels at 1.5: four whole 240s, 640 wide; in full screen none is set.
    assert_equal ["width=640px height=426.6666666666667px", "width=- height=-"],
                 sizes_for(["style screen", "click fullscreen", "style screen"], ratio: 1.5, box: "720x480")
  end
end
