# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "shell_tests"

# THE PAC-MAN PORT BUILT AS A SHELL, PLAYED AS THE DESKTOP PROGRAM (test_pacman_port_shell.rb has
# what the port and its answer keys are; test_native_shell.rb how the program is driven). It takes a
# copy of pacman.gba in place of the file dialog, keeps the pack in the folder it is told, and plays
# Pac-Man on the tape as the example built for the desktop does. Loaded only under SDL=1, like
# test_native_shell.rb.
class TestNativePacmanPortShell < Minitest::Test
  include PacmanShellTests

  Native = VBlank::IR::Backends::Native

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  MENU_KEYS = (["0", "0", "1"] + ["0"] * 20).map { |line| "#{line}\n" }.join.freeze

  # The buttons the scripted window reads, one bit each (rg_sdl.c, --scripted-keys).
  BUTTON_BITS = { a: 1, b: 2, select: 4, start: 8, right: 16, left: 32, up: 64, down: 128 }.freeze

  # The tape as the script of a scripted run: a line a frame, the buttons held as one number.
  SCRIPT = (1..GAME_PASSES).map { |pass| "#{TAPE.fetch(pass, []).sum { |button| BUTTON_BITS.fetch(button) }}\n" }.join.freeze

  # The window is 3 times the console's screen, a 24-bit BMP written bottom row first; the status
  # words of the run are at its top and bottom, so the game is the rows between.
  BMP_HEADER_BYTES = 54
  BMP_ROW_BYTES = 720 * 3
  BMP_ROWS = 480
  GAME_ROWS = (120...360)

  private def game_rows_of(bmp)
    GAME_ROWS.map { |from_top| bmp.byteslice(BMP_HEADER_BYTES + ((BMP_ROWS - 1 - from_top) * BMP_ROW_BYTES), BMP_ROW_BYTES) }
  end

  # A run on the tape: the game's variables at its end, its last picture, and what it wrote to its
  # error stream.
  Played = Data.define(:variables, :picture, :complaints)

  private def play(exe, dir, name, options: [])
    picture = File.join(dir, "#{name}.bmp")
    run = Native::Zig.run_program(exe, args: ["--scripted-keys", GAME_PASSES, "--settings-file", File.join(dir, "none-#{name}.txt"),
                                              "--window-picture", picture, *options],
                                       input: SCRIPT, env: NO_SCREEN_OR_SPEAKER, seconds: 480, complaints: true)
    Played.new(variables: Native::HeadlessRun.variables_in(run.printed.lines.map(&:chomp)), picture: game_rows_of(File.binread(picture)),
               complaints: run.complaints)
  end

  private def shell_options(dir, copy: nil)
    keys = File.join(dir, "menu.keys")
    File.write(keys, MENU_KEYS)
    ["--pack-folder", File.join(dir, "kept"), "--shell-menu-keys", keys, *(copy ? ["--shell-copy", copy] : [])]
  end

  private def kept_pack(dir) = File.binread(File.join(dir, "kept", "data.pack"))

  # The example's variables are the port's too, with the same numbers; the port has a few of its
  # own besides (the loop that lays its room out from the cartridge's map).
  private def assert_plays_as(answer, played, what)
    assert_equal answer.variables, played.variables.slice(*answer.variables.keys), "#{what}: the variables at the end of the tape"
    assert_equal answer.picture, played.picture, "#{what}: the picture at the end of the tape"
  end

  def test_the_shell_a_player_runs_plays_pacman_as_the_example_does
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(port_without_copy, File.join(dir, "pacman-shell"), console: :gba, err: nil)
      example = Native.new.build_desktop(Pacman::GAME, File.join(dir, "example"), console: :gba, err: nil)
      answer = play(example, dir, "answer")
      exe = File.join(shell, "pacman-shell")

      assert_operator answer.picture.join.bytes.uniq.size, :>, 3, "the maze is on the picture"
      assert_holds_none_of original_pieces, folder_bytes(shell), "the desktop shell's folder"

      copy = copy_of_the_cartridge(dir)
      assert_plays_as answer, play(exe, dir, "first", options: shell_options(dir, copy: copy)), "the first start"
      assert_equal all_in_one_pack, kept_pack(dir), "the pack is the all-in-one build's, byte for byte"

      File.delete(copy)
      assert_plays_as answer, play(exe, dir, "second", options: ["--pack-folder", File.join(dir, "kept")]), "the second start"

      newer = Native.new.build_desktop_shell(port_without_copy(version: "2"), File.join(dir, "pacman-shell-2"), console: :gba, err: nil)
      third = play(File.join(newer, "pacman-shell-2"), dir, "newer", options: shell_options(dir, copy: copy_of_the_cartridge(dir)))

      assert_includes third.complaints, "not the data pack this build reads"
      assert_plays_as answer, third, "a new build"
      assert_equal all_in_one_pack(version: "2"), kept_pack(dir)
    end
  end
end
