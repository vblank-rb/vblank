# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "folder_original"

# A SHELL OF A PORT WHOSE ORIGINAL IS A FOLDER OF FILES (FolderOriginal's fixture), played as the
# desktop program. LOAD ROM takes the folder, finds each file the release names in any case, checks
# each by its size and SHA-1, joins them in the release's order and unpacks them, leaving the other
# files in it alone; it refuses a folder or a file in the words the Ruby shell uses
# (test/lowering/ruby/vblank/live/test_shell_folder.rb). The answer key is the pack the all-in-one
# build makes from the same folder.
#
# Like test_native_shell.rb it builds with SDL, so it is loaded only under SDL=1, and names the folder
# (--shell-copy) and a script of buttons for the menu (--shell-menu-keys) where a person picks them.
class TestNativeShellFolder < Minitest::Test
  include FolderOriginal

  Native = VBlank::IR::Backends::Native
  Computer = VBlank::IR::Backends::Computer

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  GAME_FRAMES = 8

  # The menu's first line, LOAD ROM, chosen with A on its third frame.
  MENU_KEYS = (["0", "0", "1"] + ["0"] * 20).map { |line| "#{line}\n" }.join.freeze

  def test_the_shell_takes_a_folder_and_refuses_what_is_no_release
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(folder_port(folder_original(nil)), File.join(dir, "folder-shell"), console: :gba, err: nil)
      exe = File.join(shell, File.basename(shell))

      assert_unpacks_the_folder_and_keeps_the_pack(exe, dir)
      assert_refused_in_the_ruby_shells_words(exe, dir)
    end
  end

  # The folder's files are found in any case (the fixture's data.mu1 is DATA.MU1 to the release), and
  # the files no part of the release (CONFIG.MU1, README.TXT) are left alone.
  private def assert_unpacks_the_folder_and_keeps_the_pack(exe, dir)
    played = play(exe, dir, copy: fixture_copy_in(dir))

    refute_empty played, "the game played"
    assert_equal folder_port(folder_original).data_pack_file, File.binread(File.join(dir, "kept", "data.pack")),
                 "the pack is the all-in-one build's, byte for byte"
  end

  private def assert_refused_in_the_ruby_shells_words(exe, dir)
    lacking = File.join(dir, "lacking").tap { |into| FileUtils.mkdir_p(into) }
    FileUtils.rm(File.join(fixture_copy_in(lacking), "INDEX.MU1"))
    changed = File.join(dir, "changed").tap { |into| FileUtils.mkdir_p(into) }
    File.binwrite(File.join(fixture_copy_in(changed), "INDEX.MU1"), "MUIX".b + ("\x00".b * 14))
    { File.join(lacking, "copy") => "copy does not hold a whole release of Folder Game: the MU1 release lacks INDEX.MU1",
      File.join(changed, "copy") => "copy/INDEX.MU1 is not the file of the MU1 release of Folder Game",
      File.join(FOLDER, "data.mu1") => "data.mu1 is one file. A copy of Folder Game is a folder" }.each do |picked, words|
      FileUtils.rm_rf(File.join(dir, "kept"))
      refused = assert_raises(Computer::Error) { play(exe, dir, copy: picked) }

      assert_includes refused.message, words
      refute File.exist?(File.join(dir, "kept", "data.pack"))
    end
  end

  # The shell played with LOAD ROM picking +copy+, its pack kept in dir/kept: the game's variables at
  # the end of the script.
  private def play(exe, dir, copy:)
    keys = File.join(dir, "menu.keys")
    File.write(keys, MENU_KEYS)
    run = Computer::ProgramRun.run(exe, args: ["--scripted-keys", GAME_FRAMES, "--settings-file", File.join(dir, "none.txt"),
                                              "--pack-folder", File.join(dir, "kept"), "--shell-menu-keys", keys,
                                              "--shell-copy", copy],
                                       input: "0\n" * GAME_FRAMES, env: NO_SCREEN_OR_SPEAKER, seconds: 240, complaints: true)
    Native::HeadlessRun.variables_in(run.printed.lines.map(&:chomp))
  end
end
