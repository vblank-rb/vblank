# frozen_string_literal: true

require "test_helper"
require "web_page"
require "json"
require "tmpdir"
require "vblank/live"
require "shell_screen_tests"

# A SHELL'S FIRST SCREEN MADE THE GAME'S OWN, IN A WEB PAGE (`shell_screen`; ShellScreenTests has
# the port and the answer key). The browser is node with a stand-in for it (page_harness.js), as in
# test_js_shell.rb. Each picture the page shows is held to the same screen drawn by a plain game,
# pixel for pixel, and LOAD ROM still unpacks the copy and plays the game.
class TestJSShellScreen < Minitest::Test
  include WebPage
  include ShellScreenTests

  JS = VBlank::IR::Backends::JS

  # A key pressed and let go, with the frames that see it.
  private def tap(key) = ["down #{key}", "play 2", "up #{key}", "play 2"]

  # The picture a plain game shows once it is drawing, as the runtime written in Ruby draws it.
  private def picture_of(program)
    device = VBlank::Live::Headless.new(frames: 3)
    VBlank::Live::Session.new(program).play(device)
    device.pictures.last.pixels
  end

  private def open_styled_shell(folder, steps)
    path = File.join(folder, "shell.html")
    JS.new.build_shell_page(styled_port_without_copy(folder), path, console: :gba, err: nil)
    played_page(steps, html: File.read(path, encoding: Encoding::UTF_8), browser: ["idb:#{File.join(folder, 'idb.json')}"])
  end

  def test_the_page_draws_the_screen_a_plain_game_draws
    Dir.mktmpdir do |folder|
      out = open_styled_shell(folder, ["settle", "play 3", "picture", *tap("ArrowDown"), "picture", *tap("KeyX"), "picture",
                                       "play 14", "picture", *tap("KeyZ"), "picture"])
      first, on_credits, chosen, credits, back = pictures_in(out)

      assert_same_pixels picture_of(first_screen_drawn_plainly), first, "on the first picture"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE)), on_credits, "after down"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE, chosen: true)), chosen, "with CREDITS chosen"
      assert_same_pixels picture_of(first_screen_drawn_plainly(credits: true)), credits, "with the credits scene up"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE)), back, "back at the menu"
    end
  end

  # LOAD ROM is the first line still: chosen, it opens the picker, and the copy is unpacked and kept.
  def test_load_rom_still_unpacks_the_copy_after_a_visit_to_the_games_own_line
    Dir.mktmpdir do |folder|
      out = open_styled_shell(folder, ["settle", "play 3", *tap("ArrowDown"), *tap("KeyX"), "play 14", *tap("KeyZ"), *tap("ArrowUp"),
                                       "down KeyX", "play 3", "up KeyX", "play 12", "settle", "picker", "choose #{copy_at(folder)}",
                                       "play 2", "settle", "play 6"])
      kept = JSON.parse(File.read(File.join(folder, "idb.json"))).values.first

      assert_includes out, "picker 1"
      assert_equal all_in_one_pack, kept.unpack1("m").b
    end
  end
end
