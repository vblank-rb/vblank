# frozen_string_literal: true

require "test_helper"
require "web_page"

# The save buttons on the web page: Export save downloads the save memory as a .sav file, and Import
# save puts such a file back and starts the game again with it (runtime/rg_mount.js, mount_saves).
# The game itself is the answer key: it shows the number it was saved with.
class TestJSPageSaves < Minitest::Test
  include WebPage

  # A square at the save's number: 7 on a new cartridge, 30 once Right has been held.
  private def saving_game
    VBlank.game "SAVER", consoles: %i[gba] do
      screen :bitmap
      best = save_var :best, 7
      game_loop do
        best = 30 if held(:right)
        clear_screen :black
        draw_rect_at best, 20, 4, 4, :green
      end
    end
  end

  # Each file the page downloaded: [name, bytes].
  private def downloads_in(lines)
    lines.grep(/\Adownloaded \S/).map { |line| name, hex = line.delete_prefix("downloaded ").split(" "); [name, [hex].pack("H*")] }
  end

  private def lit?(picture, x, y) = picture[y * 240 + x] != 0

  # The save a game that held Right keeps, exported from the page: the file's bytes.
  private def exported_save(folder)
    out = played_page(["down ArrowRight", "play 10", "up ArrowRight", "play 10", "click save-export", "downloaded"], saving_game)
    path = File.join(folder, "exported.sav")
    File.binwrite(path, downloads_in(out).fetch(0)[1])
    path
  end

  def test_a_game_without_save_memory_has_no_save_buttons
    refute_includes built_page(walking_game), 'id="saves"'
    assert_includes built_page(saving_game), 'id="saves"'
  end

  def test_export_downloads_the_save_memory_as_a_sav_file
    out = played_page(["play 10", "click save-export", "downloaded", "js localStorage.getItem(\"vblank-save:SAVER\")"], saving_game)
    files = downloads_in(out)
    kept = out.grep(/\Ajs /).last.delete_prefix("js ").unpack1("m")

    assert_equal 1, files.size
    assert_equal "SAVER.sav", files[0][0]
    assert_equal kept, files[0][1]
    assert_equal kept.bytesize, files[0][1].bytesize
  end

  def test_an_imported_save_is_kept_and_the_game_starts_again_with_it
    Dir.mktmpdir do |folder|
      exported = exported_save(folder)
      storage = File.join(folder, "b-storage.json")
      b = played_page(["play 3", "click save-import", "choose #{exported}", "settle", "confirmed", "reloads"], saving_game,
                      browser: ["local-storage:#{storage}"])

      assert_includes b, "reloads 1"
      assert_match(/Replace this game's save with the save in exported\.sav\?/, b.grep(/\Aconfirmed /).first)

      picture = pictures_in(played_page(["play 3", "picture"], saving_game, browser: ["local-storage:#{storage}"])).first
      assert lit?(picture, 31, 21), "the game did not read the imported save"
      refute lit?(picture, 8, 21)
    end
  end

  def test_a_file_of_another_size_is_refused_in_plain_words
    Dir.mktmpdir do |folder|
      short = File.join(folder, "short.sav")
      File.binwrite(short, "abc")
      out = played_page(["play 3", "click save-import", "choose #{short}", "settle", "text said", "reloads", "confirmed"], saving_game)
      said = out.grep(/\Atext said /).first

      refute_match(/ hidden /, said)
      assert_match(/short\.sav is not a save of this game/, said)
      assert_match(/this file is 3 bytes/, said)
      assert_includes out, "reloads 0"
      assert_includes out, "confirmed "
    end
  end

  def test_an_import_the_player_declines_changes_nothing
    Dir.mktmpdir do |folder|
      exported = exported_save(folder)
      storage = File.join(folder, "storage.json")
      out = played_page(["play 3", "click save-import", "choose #{exported}", "settle", "reloads", "play 3", "picture"], saving_game,
                        browser: ["local-storage:#{storage}", "confirm-no"])
      picture = pictures_in(out).first

      assert_includes out, "reloads 0"
      assert lit?(picture, 8, 21)
      refute lit?(picture, 31, 21)
    end
  end

  def test_closing_the_picker_changes_nothing
    out = played_page(["play 3", "click save-import", "cancel-pick", "settle", "reloads", "confirmed"], saving_game)

    assert_includes out, "reloads 0"
    assert_includes out, "confirmed "
  end
end
