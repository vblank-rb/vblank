# frozen_string_literal: true

require "test_helper"
require "shell_tests"
require "fileutils"
require "tmpdir"

# A PORT BUILT AS A SHELL, PLAYED AS THE DESKTOP PROGRAM. The program holds none of the made-up
# original's data (ShellTests). Started with no data pack in its folder it plays its menu part;
# LOAD ROM takes the file the player picks, checks it is a release the game reads, plays the
# release's unpacking part, keeps the pack in the folder and plays the game. The next start plays the
# game from the kept pack and never reads the copy.
#
# Like test_native_desktop.rb it builds with SDL, so it is loaded only under SDL=1. The file dialog
# and the menu's buttons are what a person does, so a test names in their place the file
# (--shell-copy) and a script of buttons for the menu (--shell-menu-keys); the program is otherwise
# the one a player runs, with SDL's stand-in for a display. The answer key is the same game built
# all-in-one, played the same number of frames, and the pack the all-in-one build makes.
class TestNativeShell < Minitest::Test
  include ShellTests

  Native = VBlank::IR::Backends::Native

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  GAME_FRAMES = 8

  # The menu's first line chosen with A on its third frame.
  MENU_KEYS = (["0", "0", "1"] + ["0"] * 20).map { |line| "#{line}\n" }.join.freeze

  # The window is 3 times the console's screen, as a 24-bit BMP written bottom row first. Its top and
  # bottom carry the status words of the run, which differ between runs, so the game's picture is the
  # rows the marker is drawn on (screen rows 40 to 44), where the heights unpacked from the copy
  # decide how far across it stands.
  BMP_HEADER_BYTES = 54
  BMP_ROW_BYTES = 720 * 3
  BMP_ROWS = 480
  MARKER_ROWS = (120...135)

  private def marker_rows_of(bmp)
    MARKER_ROWS.map { |from_top| bmp.byteslice(BMP_HEADER_BYTES + ((BMP_ROWS - 1 - from_top) * BMP_ROW_BYTES), BMP_ROW_BYTES) }
  end

  # What one run of the program printed (its variables at the end of the script) and the window as it ended.
  Played = Data.define(:variables, :picture)

  def test_the_shell_a_player_runs
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(port(original(dir)), File.join(dir, "made-up-shell"), console: :gba, err: nil)
      all_in_one = Native.new.build_desktop(port(original(dir)), File.join(dir, "all-in-one"), console: :gba, err: nil)
      answer = play(all_in_one, dir, "answer")

      assert_includes marker_rows_of(answer.picture).join, "\xFF\xFF\xFF".b, "the marker is on the picture"

      assert_equal %w[made-up-shell parts], Dir.children(shell).sort
      assert_unpacks_keeps_the_pack_and_plays_the_game(shell, dir, answer)
      assert_plays_from_the_kept_pack_with_the_copy_gone(shell, dir, answer)
      assert_asks_again_for_a_pack_made_for_another_build(shell, dir)
      assert_refuses_files_that_are_no_release(shell, dir)
    end
  end

  # The game as the window plays it for GAME_FRAMES frames with nothing held.
  private def play(exe, dir, name, options: [])
    picture = File.join(dir, "#{name}.bmp")
    printed = Native::Zig.run_program(exe, args: ["--scripted-keys", GAME_FRAMES, "--settings-file", File.join(dir, "none-#{name}.txt"),
                                                  "--window-picture", picture, *options],
                                           input: "0\n" * GAME_FRAMES, env: NO_SCREEN_OR_SPEAKER, seconds: 240)
    Played.new(variables: Native::HeadlessRun.variables_in(printed.lines.map(&:chomp)), picture: File.binread(picture))
  end

  private def shell_options(dir, copy: nil)
    keys = File.join(dir, "menu.keys")
    File.write(keys, MENU_KEYS)
    ["--pack-folder", File.join(dir, "kept"), "--shell-menu-keys", keys, *(copy ? ["--shell-copy", copy] : [])]
  end

  private def shell_exe(shell) = File.join(shell, File.basename(shell))

  private def kept_pack(dir) = File.binread(File.join(dir, "kept", "data.pack"))

  private def assert_unpacks_keeps_the_pack_and_plays_the_game(shell, dir, answer)
    played = play(shell_exe(shell), dir, "first", options: shell_options(dir, copy: copy_at(dir)))

    assert_equal answer.variables, played.variables
    assert_equal marker_rows_of(answer.picture), marker_rows_of(played.picture)
    assert_equal ALL_IN_ONE_PACK, kept_pack(dir), "the pack is the all-in-one build's, byte for byte"
  end

  private def assert_plays_from_the_kept_pack_with_the_copy_gone(shell, dir, answer)
    File.delete(File.join(dir, "made_up.gba"))
    played = play(shell_exe(shell), dir, "second", options: ["--pack-folder", File.join(dir, "kept")])

    assert_equal answer.variables, played.variables
    assert_equal marker_rows_of(answer.picture), marker_rows_of(played.picture)
  end

  # A pack names the build of the game it was made for: one made for another build is refused, and
  # the copy is asked for again.
  private def assert_asks_again_for_a_pack_made_for_another_build(shell, dir)
    older = VBlank::Original::Pack.holding({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") },
                                           sha1: SHA1, build_version: "2").to_bytes
    File.binwrite(File.join(dir, "kept", "data.pack"), older)
    played = play(shell_exe(shell), dir, "third", options: shell_options(dir, copy: copy_at(dir)))

    refute_empty played.variables
    assert_equal ALL_IN_ONE_PACK, kept_pack(dir)
  end

  private def assert_refuses_files_that_are_no_release(shell, dir)
    FileUtils.rm_rf(File.join(dir, "kept"))
    { wrong_copy_at(dir) => "not a release of Made Up that this game knows", short_copy_at(dir) => "is 100 bytes" }.each do |file, words|
      refused = assert_raises(Native::Zig::Error) { play(shell_exe(shell), dir, "refused", options: shell_options(dir, copy: file)) }

      assert_includes refused.message, words
      refute File.exist?(File.join(dir, "kept", "data.pack"))
    end
  end
end
