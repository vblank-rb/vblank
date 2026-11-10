# frozen_string_literal: true

require "test_helper"
require "web_page"
require "shell_tests"
require "json"

# A PORT BUILT AS A SHELL, PLAYED AS A WEB PAGE (runtime/rg_shell.js). The page holds none of the
# made-up original's data (ShellTests). Opened with no pack kept, it shows its menu; LOAD ROM opens
# the browser's file picker, the page checks the file, unpacks it with the game's own routine, keeps
# the pack in the browser's storage (IndexedDB) and plays the game. Opened again, it plays from the
# kept pack and never asks for the file.
#
# The browser is node with a stand-in for it (page_harness.js): its file picker is given a file by
# the "choose" step, and its IndexedDB is kept in a file between runs of the page, so a second run
# finds what the first kept. The answer key is the same game built all-in-one and played the same
# number of frames, and the pack the all-in-one build makes.
class TestJSShell < Minitest::Test
  include WebPage
  include ShellTests

  JS = VBlank::IR::Backends::JS

  # How many frames of the game each test watches.
  GAME_FRAMES = 6

  # The menu's first line chosen with A (the page's X key).
  CHOOSE_LOAD_ROM = ["settle", "play 3", "down KeyX", "play 3", "up KeyX", "settle"].freeze

  # What the unpacking and the game after it show: the unpacking plays in one browser frame.
  private def unpack_and_play = ["play 2", "settle", "play #{GAME_FRAMES}", "picture"]

  private def shell_page_html(folder, version: "1")
    path = File.join(folder, "shell.html")
    JS.new.build_shell_page(port_without_copy(folder, version: version), path, console: :gba, err: nil)
    File.read(path, encoding: Encoding::UTF_8)
  end

  # The page opened once, with the browser's storage in +folder+, and what it printed.
  private def open_shell(folder, steps, version: "1")
    played_page(steps, html: shell_page_html(folder, version: version), browser: ["idb:#{File.join(folder, 'idb.json')}"])
  end

  # The picture the all-in-one build's page shows, built in a folder of its own so the copy it
  # writes is never the one a test takes out of reach.
  private def all_in_one_picture
    Dir.mktmpdir do |folder|
      path = File.join(folder, "all_in_one.html")
      JS.new.build_page(port(original(folder)), path, console: :gba, err: nil)
      pictures_in(played_page(["settle", "play #{GAME_FRAMES}", "picture"], html: File.read(path, encoding: Encoding::UTF_8))).last
    end
  end

  # The pack the page kept, or nil.
  private def kept_pack(folder)
    path = File.join(folder, "idb.json")
    return nil unless File.exist?(path)

    text = JSON.parse(File.read(path)).values.first
    text && text.unpack1("m").b
  end

  private def said(lines) = lines.grep(/\Asaid /).last

  def test_the_first_visit_unpacks_the_copy_keeps_the_pack_and_plays_the_game
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "picker", "choose #{copy_at(folder)}", *unpack_and_play])

      assert_includes out, "picker 1"
      assert_nil said(out)
      assert_same_picture all_in_one_picture, pictures_in(out).last, "after the unpacking"
    end
  end

  def test_the_pack_the_page_keeps_is_the_all_in_one_builds_byte_for_byte
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play])

      assert_equal all_in_one_pack, kept_pack(folder)
    end
  end

  def test_the_next_visit_plays_from_the_kept_pack_with_the_copy_gone
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play])
      File.delete(File.join(folder, "made_up.gba"))
      out = open_shell(folder, ["settle", "play #{GAME_FRAMES}", "picture", "picker"])

      refute File.exist?(File.join(folder, "made_up.gba"))
      assert_includes out, "picker 0"
      assert_same_picture all_in_one_picture, pictures_in(out).last, "from the kept pack"
    end
  end

  # A pack names the build of the game it was made for: a new build refuses the pack an older one
  # kept, asks for the copy again, and keeps a pack of its own.
  def test_a_new_build_of_the_port_asks_for_the_copy_again
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play])
      out = open_shell(folder, ["settle", "text said", "play 3", "picker"], version: "2")

      assert_match "not the data pack this build reads", out.grep(/\Atext said/).first
      assert_includes out, "picker 0"

      again = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play], version: "2")

      assert_nil said(again)
      assert_equal all_in_one_pack(version: "2"), kept_pack(folder)
    end
  end

  def test_a_copy_of_the_right_size_that_is_no_release_is_refused
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{wrong_copy_at(folder)}", "play 3", "text said"])

      assert_match "not a release of Made Up that this game knows", out.grep(/\Atext said/).first
      assert_nil kept_pack(folder)
    end
  end

  def test_a_file_no_release_is_the_size_of_is_refused_naming_the_size
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{short_copy_at(folder)}", "play 3", "text said"])

      assert_match "is 100 bytes", out.grep(/\Atext said/).first
      assert_nil kept_pack(folder)
    end
  end

  # A picker closed with no file leaves the menu to be played again.
  def test_closing_the_picker_with_no_file_shows_the_menu_again
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "cancel-pick", "settle", "play 3", "down KeyX", "play 3", "up KeyX", "settle", "picker"])

      assert_includes out, "picker 2"
    end
  end

  # AN UNPACKING THAT WORKS A LONG TIME BETWEEN WRITES plays in a worker, so the page keeps getting
  # its frames the whole time, and the pack it keeps is still the all-in-one build's. Played in the
  # page, as it was, the page could do nothing else until the routine waited for a frame, and this
  # one waits for none as it works.
  BUSY_STEPS = 60_000_000 # ShellTests#busy_port's: enough to keep the game as JavaScript at work for many frames

  def test_the_page_keeps_getting_frames_while_the_unpacking_works_between_writes
    Dir.mktmpdir do |folder|
      path = File.join(folder, "busy.html")
      JS.new.build_shell_page(busy_port(original_nowhere(folder), steps: BUSY_STEPS), path, console: :gba, err: nil)
      out = played_page([*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", "work", "settle"],
                        html: File.read(path, encoding: Encoding::UTF_8), browser: ["idb:#{File.join(folder, 'idb.json')}"])
      frames = out.grep(/\Aworked /).first[/frames=(\d+)/, 1].to_i

      assert_operator frames, :>=, 10, "the page had #{frames} frames as the unpacking worked"
      assert_equal Dir.mktmpdir { |other| busy_port(original(other), steps: 1).data_pack_file }, kept_pack(folder)
    end
  end

  # A browser that refuses the page a worker (a content security policy can) still unpacks: in the
  # page, as before there was a worker.
  def test_a_browser_that_refuses_a_worker_unpacks_in_the_page
    Dir.mktmpdir do |folder|
      out = played_page([*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play],
                        html: shell_page_html(folder), browser: ["idb:#{File.join(folder, 'idb.json')}", "refuse-worker"])

      assert_nil said(out)
      assert_equal all_in_one_pack, kept_pack(folder)
    end
  end

  def test_the_page_holds_none_of_the_originals_bytes
    Dir.mktmpdir do |folder|
      assert_holds_none_of original_pieces, shell_page_html(folder), "the web page"
    end
  end
end
