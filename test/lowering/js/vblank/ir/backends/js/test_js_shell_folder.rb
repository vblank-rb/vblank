# frozen_string_literal: true

require "test_helper"
require "web_page"
require "folder_original"
require "fileutils"
require "json"
require "tmpdir"

# A SHELL OF A PORT WHOSE ORIGINAL IS A FOLDER OF FILES (FolderOriginal's fixture), played as a web
# page. LOAD ROM opens the browser's folder picker; the page finds each file the release names in any
# case among the folder's own files, checks each by its size and SHA-1, joins them in the release's
# order and unpacks them, and reads nothing else. It refuses a folder in the words the Ruby shell uses
# (test/lowering/ruby/vblank/live/test_shell_folder.rb). A browser's folder picker gives no single
# file, so the refusal of one is the desktop's (test_native_shell_folder.rb).
#
# The browser is node with a stand-in for it (page_harness.js), whose picker is handed the folder by
# the "choose" step. The answer key is the pack the all-in-one build makes from the same folder.
class TestJSShellFolder < Minitest::Test
  include WebPage
  include FolderOriginal

  JS = VBlank::IR::Backends::JS

  # The menu's first line, LOAD ROM, chosen with A (the page's X key).
  CHOOSE_LOAD_ROM = ["settle", "play 3", "down KeyX", "play 3", "up KeyX", "play 12", "settle"].freeze

  private def open_shell(folder, steps)
    path = File.join(folder, "shell.html")
    JS.new.build_shell_page(folder_port(folder_original(nil)), path, console: :gba, err: nil)
    played_page(steps, html: File.read(path, encoding: Encoding::UTF_8), browser: ["idb:#{File.join(folder, 'idb.json')}"])
  end

  # The pack the page kept, or nil.
  private def kept_pack(folder)
    path = File.join(folder, "idb.json")
    return nil unless File.exist?(path)

    text = JSON.parse(File.read(path)).values.first
    text && text.unpack1("m").b
  end

  private def refusal_picking(folder, picked) = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{picked}", "play 3", "text said"]).grep(/\Atext said/).first

  def test_the_page_takes_a_folder_and_keeps_the_all_in_one_pack
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{fixture_copy_in(folder)}", "play 2", "settle"])

      assert_equal folder_port(folder_original).data_pack_file, kept_pack(folder), "byte for byte"
    end
  end

  # A file of the release in a folder inside the one picked is not the folder's own, as a browser
  # lists it with its path, so the release still lacks it.
  def test_a_folder_without_a_file_of_the_release_is_refused_naming_it
    Dir.mktmpdir do |folder|
      copy = fixture_copy_in(folder)
      FileUtils.mkdir_p(File.join(copy, "old"))
      FileUtils.mv(File.join(copy, "INDEX.MU1"), File.join(copy, "old", "INDEX.MU1"))

      assert_match "copy does not hold a whole release of Folder Game: the MU1 release lacks INDEX.MU1", refusal_picking(folder, copy)
      assert_nil kept_pack(folder)
    end
  end

  def test_a_changed_file_is_refused_naming_it
    Dir.mktmpdir do |folder|
      copy = fixture_copy_in(folder)
      File.binwrite(File.join(copy, "INDEX.MU1"), "MUIX".b + ("\x00".b * 14))

      assert_match "copy/INDEX.MU1 is not the file of the MU1 release of Folder Game", refusal_picking(folder, copy)
      assert_nil kept_pack(folder)
    end
  end
end
