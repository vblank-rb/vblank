# frozen_string_literal: true

require "test_helper"
require "web_page"

# The page asks the browser to keep its data once the game saves, and says when the browser cleared
# the game's save anyway: a cookie set with each save marks that there was one (rg_page.js,
# page_create). The game is the answer key: it shows the number it was saved with.
class TestJSPageKeptStorage < Minitest::Test
  include WebPage

  # The cookie that marks the save of the game below.
  MARKER = "vblank-kept-vblank-save%3AKEEPS"

  # A square at the save's number: 7 on a new cartridge, 30 once Right has been held.
  private def keeping_game
    VBlank.game "KEEPS", consoles: %i[gba] do
      screen :bitmap
      best = save_var :best, 7
      game_loop do
        best = 30 if held(:right)
        clear_screen :black
        draw_rect_at best, 20, 4, 4, :green
      end
    end
  end

  private def lit?(picture, x, y) = picture[y * 240 + x] != 0

  def test_the_page_asks_to_keep_its_data_once_the_game_saves
    out = played_page(["play 10", "persist", "cookie"], keeping_game)

    assert_includes out, "persist 1"
    assert_includes out.grep(/\Acookie /).first, "#{MARKER}=1"

    without = played_page(["play 10", "persist", "cookie"], walking_game)

    assert_includes without, "persist 0"
    refute_includes without.grep(/\Acookie /).first, "vblank-kept"
  end

  def test_a_save_the_browser_cleared_is_said
    out = played_page(["text said", "cookie", "play 10", "cookie"], keeping_game, browser: ["cookie:#{MARKER}=1"])
    said = out.grep(/\Atext said /).first
    first, second = out.grep(/\Acookie /)

    refute_match(/ hidden /, said)
    assert_match(/cleared the game's save/, said)
    refute_includes first, MARKER
    assert_includes second, "#{MARKER}=1"
  end

  def test_a_kept_save_is_not_said_to_be_cleared
    Dir.mktmpdir do |folder|
      storage = File.join(folder, "storage.json")
      played_page(["play 10"], keeping_game, browser: ["local-storage:#{storage}"])
      out = played_page(["play 3", "text said"], keeping_game, browser: ["local-storage:#{storage}", "cookie:#{MARKER}=1"])

      assert_match(/ hidden /, out.grep(/\Atext said /).first)
    end
  end

  def test_a_browser_that_refuses_to_keep_data_plays_on
    out = played_page(["play 10", "picture", "persist"], keeping_game, browser: ["persist-refused"])

    assert_includes out, "persist 1"
    assert lit?(pictures_in(out).first, 8, 21)
  end
end
