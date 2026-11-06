# frozen_string_literal: true

require "test_helper"
require "web_page"
require "json"
require VBlank.root.join("examples/pacman").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_port").to_s

# THE PAC-MAN PORT BUILT AS A SHELL, PLAYED AS A WEB PAGE (test_pacman_port_shell.rb says what the
# port and its answer keys are). The page takes pacman.gba at Load ROM, unpacks it with the port's own
# routine, keeps the pack in the browser's storage, and plays Pac-Man as examples/pacman.rb does.
class TestJSPacmanPortShell < Minitest::Test
  include WebPage

  JS = VBlank::IR::Backends::JS
  GAME_FRAMES = 30
  CHOOSE_LOAD_ROM = ["settle", "play 3", "down KeyX", "play 3", "up KeyX", "settle"].freeze
  AFTER_CHOOSING = ["play 2", "settle", "play #{GAME_FRAMES}", "picture"].freeze

  private def shell_html(folder)
    path = File.join(folder, "shell.html")
    JS.new.build_shell_page(PacmanPort.game(PacmanPort.original(env: {})), path, console: :gba, err: nil)
    File.read(path, encoding: Encoding::UTF_8)
  end

  private def open_shell(folder, steps)
    played_page(steps, html: shell_html(folder), browser: ["idb:#{File.join(folder, 'idb.json')}"])
  end

  # The example, built as a page and played the same number of frames.
  private def example_picture(folder)
    path = File.join(folder, "example.html")
    JS.new.build_page(Pacman::GAME, path, console: :gba, err: nil)
    pictures_in(played_page(["settle", "play #{GAME_FRAMES}", "picture"], html: File.read(path, encoding: Encoding::UTF_8))).last
  end

  private def kept_pack(folder)
    path = File.join(folder, "idb.json")
    path = File.exist?(path) ? JSON.parse(File.read(path)).values.first : nil
    path && path.unpack1("m").b
  end

  def test_the_first_visit_plays_pacman_as_the_example_does_pixel_for_pixel
    Dir.mktmpdir do |folder|
      out = open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{PacmanFixture::ROM_PATH}", *AFTER_CHOOSING])

      assert_nil out.grep(/\Asaid /).last
      assert_same_picture example_picture(folder), pictures_in(out).last, "after the unpacking"
    end
  end

  def test_the_pack_the_page_keeps_is_the_cartridges_assets_unpacked_byte_for_byte
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{PacmanFixture::ROM_PATH}", *AFTER_CHOOSING])

      assert_equal PacmanFixture.expected_pack, kept_pack(folder)
    end
  end

  def test_the_next_visit_plays_from_the_kept_pack_without_asking_for_the_cartridge
    Dir.mktmpdir do |folder|
      open_shell(folder, [*CHOOSE_LOAD_ROM, "choose #{PacmanFixture::ROM_PATH}", *AFTER_CHOOSING])
      out = open_shell(folder, ["settle", "play #{GAME_FRAMES}", "picture", "picker"])

      assert_includes out, "picker 0"
      assert_same_picture example_picture(folder), pictures_in(out).last, "from the kept pack"
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
end
