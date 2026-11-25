# frozen_string_literal: true

require "test_helper"
require "web_page"
require "shell_tests"
require "json"

# A port built as a shell, played as a web page (runtime/rg_shell.js). The page holds none of the
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

  # The menu's first line chosen with A (the page's X key), and the frames it then shows as chosen
  # before the menu ends.
  CHOOSE_LOAD_ROM = ["settle", "play 3", "down KeyX", "play 3", "up KeyX", "play 12", "settle"].freeze

  # The rows of the picture LOAD ROM and settings are drawn on, and the colours a line is drawn in:
  # gray, white under the cursor, yellow once chosen (Original::Shell.menu_program).
  WIDTH = 240
  LOAD_ROM_ROWS = (80...88)
  SETTINGS_ROWS = (92...100)
  GRAY, WHITE, YELLOW = %i[gray white yellow].map { |name| VBlank::Graphics::Color.resolve(name) }

  # The colours of the words on +rows+ of +picture+ (its pixels, a row at a time), black left out.
  private def colors_on(picture, rows) = rows.flat_map { |row| picture[row * WIDTH, WIDTH] }.uniq - [0]

  # The picture up as the picker opens has LOAD ROM shown as chosen, and stays up behind it.
  def test_the_chosen_line_shows_as_chosen_as_the_picker_opens
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "picker", "picture"])

      assert_includes out, "picker 1"
      assert_equal [YELLOW], colors_on(pictures_in(out).last, LOAD_ROM_ROWS)
      assert_equal [GRAY], colors_on(pictures_in(out).last, SETTINGS_ROWS)
    end
  end

  # A picker closed with no file shows the menu as it was, from its first frame: LOAD ROM under the
  # cursor and no longer shown as chosen.
  def test_closing_the_picker_shows_the_menu_on_the_same_line
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "cancel-pick", "settle", "play 1", "picture"])

      assert_equal [WHITE], colors_on(pictures_in(out).last, LOAD_ROM_ROWS)
      assert_equal [GRAY], colors_on(pictures_in(out).last, SETTINGS_ROWS)
    end
  end

  # What the unpacking and the game after it show: the unpacking plays in one browser frame.
  private def unpack_and_play = ["play 2", "settle", "play #{GAME_FRAMES}", "picture"]

  private def shell_page_html(folder, version: "1")
    path = File.join(folder, "shell.html")
    JS.new.build_shell_page(port_without_copy(folder, version: version), path, console: :gba, err: nil)
    File.read(path, encoding: Encoding::UTF_8)
  end

  # The page opened once, with the browser's storage in +folder+, and what it printed.
  private def open_shell(folder, steps, version: "1", pointer: :mouse)
    played_page(steps, html: shell_page_html(folder, version: version), pointer: pointer,
                       browser: ["idb:#{File.join(folder, 'idb.json')}"])
  end

  # The menu's first line chosen with A on the page's touch pad, the finger lifted before the menu
  # ends: a finger landing lets the page open no picker, and the menu acts frames after the press.
  TAP_LOAD_ROM = ["settle", "play 3", "finger 1 pad-a", "play 3", "lift 1", "play 12", "settle"].freeze

  # On a phone the picker opens inside the player's next tap, and until then the page says to tap.
  def test_a_tap_on_the_pad_opens_the_picker_at_the_next_tap
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*TAP_LOAD_ROM, "picker", "text said", "finger 2 screen", "lift 2", "picker", "text said"],
                       pointer: :finger)

      assert_equal ["picker 0", "picker 1"], out.grep(/\Apicker /)
      asked, after = out.grep(/\Atext said/)
      assert_match(/choose your copy/, asked)
      assert_match(/hidden/, after)
    end
  end

  # A finger still on A as the menu ends opens the picker as it lifts.
  def test_a_finger_held_on_the_pad_opens_the_picker_as_it_lifts
    Dir.mktmpdir do |folder|
      out = open_shell(folder, ["settle", "play 3", "finger 1 pad-a", "play 15", "settle", "picker", "lift 1", "picker",
                                "choose #{copy_at(folder)}", *unpack_and_play], pointer: :finger)

      assert_equal ["picker 0", "picker 1"], out.grep(/\Apicker /)
      assert_same_picture all_in_one_picture, pictures_in(out).last, "after the unpacking"
    end
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
      assert pose_shown_in?(pictures_in(out).last, 240), "the pose read from the pack's frame record is not shown"
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

  # A pack an older build kept is routine (a port grows a part at a time): a new build does not
  # read it, tells the player of no refusal, says on its menu that the data must be read again,
  # asks for the copy as on a first visit, and keeps a pack of its own over the old one.
  READ_AGAIN_ROWS = (104...160)

  def test_a_new_build_of_the_port_asks_for_the_copy_again
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play])
      out = open_shell(folder, ["settle", "text said", "play 3", "picture", "picker"], version: "2")

      refute_match(/data pack/, out.grep(/\Atext said/).first.to_s, "a pack kept by an older build was told to the player as a refusal")
      assert_nil said(out)
      assert_equal [GRAY], colors_on(pictures_in(out).last, READ_AGAIN_ROWS), "the menu does not say the data must be read again"
      assert_includes out, "picker 0"

      again = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play], version: "2")

      assert_nil said(again)
      assert_equal all_in_one_pack(version: "2"), kept_pack(folder)
    end
  end

  # A first visit, with no pack kept, says nothing of reading the data again.
  def test_a_first_visit_does_not_say_the_data_must_be_read_again
    Dir.mktmpdir do |folder|
      out = open_shell(folder, ["settle", "play 3", "picture"])

      assert_empty colors_on(pictures_in(out).last, READ_AGAIN_ROWS)
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
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "cancel-pick", *CHOOSE_LOAD_ROM, "picker"])

      assert_includes out, "picker 2"
    end
  end

  # An unpacking that works a long time between writes plays in a worker, so the page keeps getting
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

  # The shell page with its game kept where a step can reach it, `pageGame`: the page's start
  # line mounts a createGame that keeps what it makes. The page as built keeps it to itself.
  private def page_keeping_its_game(html)
    kept = html.sub("rg_mount_page(rg_shell_game(",
                    "function rg_mount_page_kept(create) { rg_mount_page((host) => (globalThis.pageGame = create(host))); }\n" \
                    "rg_mount_page_kept(rg_shell_game(")
    refute_equal html, kept, "the shell page no longer starts with rg_mount_page(rg_shell_game(...)), so the test cannot keep its game"
    kept
  end

  # A copy dragged over the page while the menu shows gets a dashed border, and dropped there it is
  # unpacked and kept exactly as one the picker gave.
  def test_a_copy_dropped_on_the_menu_is_unpacked_and_kept
    Dir.mktmpdir do |folder|
      out = open_shell(folder, ["settle", "play 3", "drag-enter", "style screen", "drop #{copy_at(folder)}", *unpack_and_play, "picker"])

      assert_match(/outline=6px dashed #ff8800/, out.grep(/\Astyle screen /).first)
      assert_empty out.grep(/\Aopened /)
      assert_equal all_in_one_pack, kept_pack(folder)
      assert_same_picture all_in_one_picture, pictures_in(out).last, "after the drop"
      assert_includes out, "picker 0"
    end
  end

  def test_dragging_away_clears_the_border
    Dir.mktmpdir do |folder|
      out = open_shell(folder, ["settle", "play 3", "drag-enter", "drag-enter", "drag-leave", "style screen", "drag-leave", "style screen"])
      first, second = out.grep(/\Astyle screen /)

      assert_match(/outline=6px dashed #ff8800/, first)
      assert_match(/outline=-\z/, second)
    end
  end

  def test_a_folder_dropped_where_the_copy_is_one_file_is_refused
    Dir.mktmpdir do |folder|
      dropped = File.join(folder, "dropped")
      FileUtils.mkdir_p(dropped)
      FileUtils.cp(copy_at(folder), dropped)
      out = open_shell(folder, ["settle", "play 3", "drop #{dropped}", "play 3", "text said"])

      assert_match(/dropped is a folder\. A copy of Made Up is one file/, out.grep(/\Atext said /).first)
      assert_nil kept_pack(folder)
    end
  end

  # A drop is only for the menu: while the game plays it shows no border, does nothing, and is not
  # left to the browser to open in place of the page.
  def test_a_drop_while_the_game_plays_is_ignored
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play])
      File.delete(File.join(folder, "made_up.gba"))
      out = open_shell(folder, ["settle", "play 3", "drag-enter", "style screen", "drop #{copy_at(folder)}", "play #{GAME_FRAMES}", "picture"])

      assert_match(/outline=-\z/, out.grep(/\Astyle screen /).first)
      assert_empty out.grep(/\Aopened /), "the browser opened the dropped file in place of the page"
      assert_same_picture all_in_one_picture, pictures_in(out).last, "after a drop on the playing game"
    end
  end

  def test_the_shell_asks_to_keep_its_data_once_it_keeps_the_pack
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "persist", "choose #{copy_at(folder)}", *unpack_and_play, "persist"])

      assert_equal ["persist 0", "persist 1"], out.grep(/\Apersist /)
    end
  end

  # A page stopped while the unpacking works ends the worker at once and keeps no pack.
  def test_stopping_the_page_mid_unpacking_ends_the_worker_and_keeps_no_pack
    Dir.mktmpdir do |folder|
      path = File.join(folder, "busy.html")
      JS.new.build_shell_page(busy_port(original_nowhere(folder), steps: BUSY_STEPS), path, console: :gba, err: nil)
      html = page_keeping_its_game(File.read(path, encoding: Encoding::UTF_8))
      out = played_page([*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", "play 2", "wait 20", "workers",
                         "js pageGame.stop()", "workers", "play 3", "settle"],
                        html: html, browser: ["idb:#{File.join(folder, 'idb.json')}"])

      assert_equal ["workers 1", "workers 0"], out.grep(/\Aworkers /)
      assert_nil kept_pack(folder)
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

  # A long unpacking routine (ShellTests#long_routine_port), thousands of statements in one
  # routine, unpacks in the page's worker to the all-in-one build's pack, and the game plays.
  def test_a_long_unpacking_routine_unpacks_to_the_all_in_one_builds_pack
    Dir.mktmpdir do |folder|
      path = File.join(folder, "long.html")
      JS.new.build_shell_page(long_routine_port(original_nowhere(folder)), path, console: :gba, err: nil)
      out = played_page([*CHOOSE_LOAD_ROM, "choose #{copy_at(folder)}", *unpack_and_play],
                        html: File.read(path, encoding: Encoding::UTF_8), browser: ["idb:#{File.join(folder, 'idb.json')}"])

      assert_nil said(out)
      assert_equal Dir.mktmpdir { |other| long_routine_port(original(other)).data_pack_file }, kept_pack(folder)
    end
  end

  # A browser that keeps nothing for the page (an app's built-in browser showing it in a frame) gets
  # a plain message and a button that copies the page's address, and never the menu: the menu and
  # the unpacking both write to storage, and such a browser leaves them waiting for ever.
  # +wait+ is real time for the page's own check to give up on storage that never answers.
  private def open_without_storage(folder, flag, wait: 0)
    played_page(["settle", ("wait #{wait}" if wait.positive?), "settle", "play 3", "counts", "text said", "text copy-link",
                 *CHOOSE_LOAD_ROM, "picker", "click copy-link", "settle", "clipboard"].compact,
                html: shell_page_html(folder), browser: ["idb:#{File.join(folder, 'idb.json')}", *flag])
  end

  private def assert_storage_refused(out)
    assert_match(/pictures=0\b/, out.grep(/\Acounts /).first, "the menu was drawn")
    said = out.grep(/\Atext said /).first
    refute_match(/hidden/, said)
    assert_match(/cannot keep/, said)
    assert_match(/Chrome, Safari or Firefox/, said)
    refute_match(/hidden|\(none\)/, out.grep(/\Atext copy-link /).first)
    assert_includes out, "picker 0"
    assert_match(%r{\Aclipboard file://.*/page\.html\z}, out.grep(/\Aclipboard /).first)
  end

  def test_a_browser_whose_local_storage_throws_says_to_open_the_page_elsewhere
    Dir.mktmpdir { |folder| assert_storage_refused open_without_storage(folder, "no-local-storage") }
  end

  def test_a_browser_whose_indexed_db_fails_says_to_open_the_page_elsewhere
    Dir.mktmpdir { |folder| assert_storage_refused open_without_storage(folder, "idb-error") }
  end

  def test_a_browser_whose_indexed_db_never_answers_says_to_open_the_page_elsewhere
    Dir.mktmpdir { |folder| assert_storage_refused open_without_storage(folder, "idb-silent", wait: 5500) }
  end

  # A page in a frame that cannot keep the game's data copies an address that opens the game on its own:
  # the one the host gave (?link=), else the top page's, else the frame's own.
  def test_a_framed_page_copies_the_address_the_host_gave
    Dir.mktmpdir do |folder|
      out = open_without_storage(folder, ["framed", "no-local-storage",
                                          "address:file:///x/page.html?link=https%3A%2F%2Fhost.example%2Fgame"])

      assert_equal "clipboard https://host.example/game", out.grep(/\Aclipboard /).first
    end
  end

  def test_a_framed_page_with_no_address_given_copies_the_page_that_framed_it
    Dir.mktmpdir do |folder|
      out = open_without_storage(folder, ["framed", "no-local-storage", "referrer:https://host.example/play"])

      assert_equal "clipboard https://host.example/play", out.grep(/\Aclipboard /).first
    end
  end

  # A browser slow to open its storage the first time still starts the game.
  def test_a_slow_first_open_of_storage_still_starts_the_game
    Dir.mktmpdir do |folder|
      out = open_without_storage(folder, "idb-slow:3000", wait: 3500)

      refute_match(/pictures=0\b/, out.grep(/\Acounts /).first, "the menu was drawn")
      assert_match(/\Atext copy-link hidden/, out.grep(/\Atext copy-link /).first)
    end
  end

  # With storage that works the page says nothing of it, hides the button, and keeps no trace of its check.
  def test_a_browser_that_keeps_data_shows_the_menu_and_no_storage_message
    Dir.mktmpdir do |folder|
      out = open_shell(folder, ["settle", "play 3", "counts", "text said", "text copy-link"])

      refute_match(/pictures=0\b/, out.grep(/\Acounts /).first)
      assert_match(/\Atext said hidden/, out.grep(/\Atext said /).first)
      assert_match(/\Atext copy-link hidden/, out.grep(/\Atext copy-link /).first)
      assert_nil kept_pack(folder)
    end
  end

  def test_the_page_holds_none_of_the_originals_bytes
    Dir.mktmpdir do |folder|
      assert_holds_none_of original_pieces, shell_page_html(folder), "the web page"
    end
  end
end
