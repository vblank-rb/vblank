# frozen_string_literal: true

require "test_helper"
require "border_frame_tests"

# A Color game in the Advance's border, as the game as Ruby shows it in its window.
class TestRubyBorder < Minitest::Test
  include BorderFrameTests

  HeadlessRun = VBlank::IR::Backends::Ruby::HeadlessRun

  # A player that keeps each picture it is handed, for three passes, and asks for no save.
  class PictureKeeper
    attr_reader :pictures

    def initialize = @pictures = []
    def take_state_request = nil

    def buttons_after(pixels, _left, _right)
      @pictures << pixels.dup
      @pictures.size < 3 ? [0] : nil
    end
  end

  # Played live, the picture the window is handed each pass is the whole screen, border and all.
  def test_a_game_played_live_hands_its_window_the_whole_screen
    game = VBlank::IR::Backends::Ruby.new.live_game(PLAIN.program(console: :gba))
    pictures = PictureKeeper.new.tap { |player| game.play(player) }.pictures
    border = VBlank::Graphics::Border.default(whole: [240, 160], inner: [160, 144])

    assert_equal [240, 160], [game.width, game.height]
    assert_equal 240 * 160, pictures.last.size
    assert_equal border[0], pictures.last[0], "the border at the corner"
    assert_equal VBlank::Graphics::Color.resolve(:red), pictures.last[(TOP * 240) + LEFT], "the game's red bar at (40, 8)"
  end
end
