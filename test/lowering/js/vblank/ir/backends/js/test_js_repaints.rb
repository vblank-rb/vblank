# frozen_string_literal: true

require "test_helper"
require "repaint_games"

# HOW OFTEN THE JAVASCRIPT RUNTIME BUILDS THE WHOLE VIEW AGAIN. A screen that scrolls a background is built
# from its scenery and its sprites each time something asks, and the scroll and the sprites ask
# every frame, moved or not. A frame on which neither moved asks for nothing, so a game standing
# still is built a few times (the frames before the first picture) and not once a frame. The
# count is how many times the JavaScript ran its rebuild, which is exact where a time is not.
class TestJSRepaints < Minitest::Test
  include RepaintGames

  HeadlessRun = VBlank::IR::Backends::JS::HeadlessRun

  FRAMES = 30

  def test_a_screen_standing_still_is_not_rebuilt_every_frame
    assert_operator HeadlessRun.new.run(still_game, frames: FRAMES).repaints_painted, :<=, 3
  end

  def test_a_screen_scrolling_every_frame_is_rebuilt_every_frame
    assert_operator HeadlessRun.new.run(scrolling_game, frames: FRAMES).repaints_painted, :>=, FRAMES
  end
end
