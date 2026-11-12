# frozen_string_literal: true

require "test_helper"
require "web_page"
require "json"
require "tmpdir"
require "shell_tests"

# THE PAC-MAN PORT BUILT AS A SHELL, PLAYED AS A WEB PAGE (test_pacman_port_shell.rb has what the
# port and its answer keys are). The page takes a copy of pacman.gba at Load ROM, unpacks it with
# the port's own routine, keeps the pack in the browser's storage, and plays Pac-Man on the tape as
# examples/pacman.rb's page does, pixel for pixel at the end of each stretch of the tape.
class TestJSPacmanPortShell < Minitest::Test
  include WebPage
  include PacmanShellTests

  JS = VBlank::IR::Backends::JS
  CHOOSE_LOAD_ROM = ["settle", "play 3", "down KeyX", "play 3", "up KeyX", "play 12", "settle"].freeze
  # The unpacking plays in one browser frame, and the game starts after it.
  AFTER_CHOOSING = ["play 2", "settle"].freeze

  # The page's key for each button on the tape (rg_page.js, PAGE_KEYS).
  KEYS = { left: "ArrowLeft", right: "ArrowRight", up: "ArrowUp", down: "ArrowDown" }.freeze

  # The tape as steps of the page: the keys going down and up as the buttons held change, each
  # stretch of frames with the same buttons played, and the picture at the end of each stretch.
  TAPE_STEPS = (1..GAME_PASSES).chunk_while { |pass, after| TAPE.fetch(pass, []) == TAPE.fetch(after, []) }
                               .each_with_object([[], []]) do |stretch, (steps, held)|
    now = TAPE.fetch(stretch.first, [])
    steps.concat((held - now).map { |button| "up #{KEYS.fetch(button)}" }, (now - held).map { |button| "down #{KEYS.fetch(button)}" },
                 ["play #{stretch.size}", "picture"])
    held.replace(now)
  end.first.freeze

  private def shell_html(folder, version: "1")
    path = File.join(folder, "shell.html")
    JS.new.build_shell_page(port_without_copy(version: version), path, console: :gba, err: nil)
    File.read(path, encoding: Encoding::UTF_8)
  end

  private def open_shell(folder, steps, version: "1")
    played_page(steps, html: shell_html(folder, version: version), browser: ["idb:#{File.join(folder, 'idb.json')}"])
  end

  # The example, built as a page and played on the tape: its picture at the end of each stretch.
  private def example_pictures
    Dir.mktmpdir do |folder|
      path = File.join(folder, "example.html")
      JS.new.build_page(Pacman::GAME, path, console: :gba, err: nil)
      pictures_in(played_page(["settle", *TAPE_STEPS], html: File.read(path, encoding: Encoding::UTF_8)))
    end
  end

  private def kept_pack(folder)
    path = File.join(folder, "idb.json")
    path = File.exist?(path) ? JSON.parse(File.read(path)).values.first : nil
    path && path.unpack1("m").b
  end

  private def assert_plays_the_tape_as_the_example(out, what)
    expected = example_pictures
    played = pictures_in(out)

    assert_equal expected.size, played.size, "#{what}: pictures taken"
    expected.each_with_index { |picture, at| assert_same_picture picture, played[at], "#{what}, stretch #{at + 1} of the tape" }
  end

  def test_the_first_visit_plays_pacman_on_the_tape_as_the_example_does
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_of_the_cartridge(folder)}", *AFTER_CHOOSING, *TAPE_STEPS])

      assert_nil out.grep(/\Asaid /).last
      assert_plays_the_tape_as_the_example out, "the first visit"
    end
  end

  def test_the_pack_the_page_keeps_is_the_all_in_one_builds_byte_for_byte
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_of_the_cartridge(folder)}", *AFTER_CHOOSING, "play 2"])

      assert_equal all_in_one_pack, kept_pack(folder)
    end
  end

  def test_the_next_visit_plays_from_the_kept_pack_with_the_cartridge_out_of_reach
    Dir.mktmpdir do |folder|
      copy = copy_of_the_cartridge(folder)
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy}", *AFTER_CHOOSING, "play 2"])
      File.delete(copy)
      out = open_shell(folder, ["settle", *TAPE_STEPS, "picker"])

      assert_includes out, "picker 0"
      assert_plays_the_tape_as_the_example out, "the next visit"
    end
  end

  def test_a_new_build_of_the_port_asks_for_the_cartridge_again
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{copy_of_the_cartridge(folder)}", *AFTER_CHOOSING, "play 2"])
      out = open_shell(folder, ["settle", "text said", "play 3", "picker", *CHOOSE_LOAD_ROM, "choose #{copy_of_the_cartridge(folder)}",
                                *AFTER_CHOOSING, "play 2"], version: "2")

      refute_match(/data pack/, out.grep(/\Atext said/).first.to_s, "a pack kept by an older build was told to the player as a refusal")
      assert_includes out, "picker 0"
      assert_equal all_in_one_pack(version: "2"), kept_pack(folder)
    end
  end

  def test_a_file_that_is_not_the_cartridge_is_refused
    Dir.mktmpdir do |folder|
      wrong = File.join(folder, "wrong.gba")
      File.binwrite(wrong, File.binread(PacmanFixture::ROM_PATH).reverse)
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{wrong}", "play 3", "text said"])

      assert_match "not a release of Pac-Man that this game knows", out.grep(/\Atext said/).first
      assert_nil kept_pack(folder)
    end
  end

  def test_the_page_holds_none_of_the_cartridge
    Dir.mktmpdir do |folder|
      assert_holds_none_of original_pieces, shell_html(folder), "the web page"
    end
  end
end
