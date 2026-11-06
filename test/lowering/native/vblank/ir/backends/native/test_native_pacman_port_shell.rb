# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require VBlank.root.join("examples/pacman").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_fixture").to_s
require VBlank.root.join("test/fixtures/pacman_port/pacman_port").to_s

# THE PAC-MAN PORT BUILT AS A SHELL, PLAYED AS THE DESKTOP PROGRAM (test_pacman_port_shell.rb says what
# the port and its answer keys are; test_native_shell.rb how the program is driven). It takes
# pacman.gba in place of the file dialog, keeps the pack in the folder it is told, and plays Pac-Man
# as the example built for the desktop does. Loaded only under SDL=1, like test_native_shell.rb.
class TestNativePacmanPortShell < Minitest::Test
  Native = VBlank::IR::Backends::Native

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  GAME_FRAMES = 30
  MENU_KEYS = (["0", "0", "1"] + ["0"] * 20).map { |line| "#{line}\n" }.join.freeze

  # The window is 3 times the console's screen, a 24-bit BMP written bottom row first; the status
  # words of the run are at its top and bottom, so the game is the rows between.
  BMP_HEADER_BYTES = 54
  BMP_ROW_BYTES = 720 * 3
  BMP_ROWS = 480
  GAME_ROWS = (120...360)

  private def game_rows_of(bmp)
    GAME_ROWS.map { |from_top| bmp.byteslice(BMP_HEADER_BYTES + ((BMP_ROWS - 1 - from_top) * BMP_ROW_BYTES), BMP_ROW_BYTES) }
  end

  private def play(exe, dir, name, options: [])
    picture = File.join(dir, "#{name}.bmp")
    Native::Zig.run_program(exe, args: ["--scripted-keys", GAME_FRAMES, "--settings-file", File.join(dir, "none-#{name}.txt"),
                                        "--window-picture", picture, *options],
                                 input: "0\n" * GAME_FRAMES, env: NO_SCREEN_OR_SPEAKER, seconds: 480)
    game_rows_of(File.binread(picture))
  end

  def test_the_shell_a_player_runs_plays_pacman_as_the_example_does
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(PacmanPort.game(PacmanPort.original(env: {})), File.join(dir, "pacman-shell"), console: :gba, err: nil)
      example = Native.new.build_desktop(Pacman::GAME, File.join(dir, "example"), console: :gba, err: nil)
      answer = play(example, dir, "answer")

      assert_operator answer.join.bytes.uniq.size, :>, 3, "the maze is on the picture"
      keys = File.join(dir, "menu.keys")
      File.write(keys, MENU_KEYS)
      kept = File.join(dir, "kept")
      exe = File.join(shell, "pacman-shell")

      first = play(exe, dir, "first", options: ["--pack-folder", kept, "--shell-menu-keys", keys, "--shell-copy", PacmanFixture::ROM_PATH])

      assert_equal answer, first
      assert_equal PacmanFixture.expected_pack, File.binread(File.join(kept, "data.pack"))
      assert_equal answer, play(exe, dir, "second", options: ["--pack-folder", kept])
    end
  end
end
