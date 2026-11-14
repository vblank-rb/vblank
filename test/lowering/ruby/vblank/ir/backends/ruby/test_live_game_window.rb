# frozen_string_literal: true

require "test_helper"
require "vblank/live"

# The window a game built as Ruby is played in (`vblank run`, and the one Ruby file a game is
# written out as) is sized from what the game carries: its picture and the size each of its pixels
# is shown at (LiveGame#width, #height, #pixel_size). A game of big pixels hands over a picture half
# the Advance's width and height, and opens a window the same size as the same game's with pixels of
# the console's own size. The window opens on SDL's dummy video driver, which needs no screen.
class TestLiveGameWindow < Minitest::Test
  # SDL's driver is chosen from the process's settings, and Fiddle calls into C from the main Ractor only.
  runs_on_the_main_ractor!

  def setup
    @driver_before = ENV.fetch("SDL_VIDEODRIVER", nil)
    ENV["SDL_VIDEODRIVER"] = "dummy"
  end

  def teardown = ENV["SDL_VIDEODRIVER"] = @driver_before

  private def game_of(pixel_size)
    game = VBlank.game("BIGWINDOW", consoles: %i[gba]) do
      screen :bitmap, pixel_size: pixel_size
      game_loop { clear_screen :blue }
    end
    VBlank::IR::Backends::Ruby.new.live_game(game.program(console: :gba))
  end

  def test_a_game_of_big_pixels_carries_its_small_picture_and_its_pixel_size
    assert_equal [120, 80, 2], [game_of(2).width, game_of(2).height, game_of(2).pixel_size]
    assert_equal [240, 160, 1], [game_of(1).width, game_of(1).height, game_of(1).pixel_size]
  end

  def test_a_game_of_big_pixels_opens_the_window_its_plain_twin_opens
    flunk "SDL3 is not installed: #{VBlank::Live::SDL::INSTALL_LINE}" unless VBlank::Live::SDL.available?

    sizes = [1, 2].map do |size|
      game = game_of(size)
      window = VBlank::Live::SDL.new(title: "BIGWINDOW", scale: 3, width: game.width, height: game.height,
                                     pixel_size: game.pixel_size)
      window.show(Array.new(game.width * game.height, 0), game.width, game.height)
      window.window_size
    ensure
      window&.close
    end

    assert_equal [[720, 480], [720, 480]], sizes
  end
end
