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
# (--shell-copy), or what the dialog gives each time it is asked (--shell-picks), and a script of
# buttons for the menu (--shell-menu-keys); the program is otherwise the one a player runs, with
# SDL's stand-in for a display. The answer key is the same game built all-in-one, played the same
# number of frames, and the pack the all-in-one build makes.
#
# The shell has ONE WINDOW from its menu to its game: its parts have none, and send what they draw
# to the program that started them (runtime/rg_shell.c).
class TestNativeShell < Minitest::Test
  include ShellTests

  Native = VBlank::IR::Backends::Native
  Computer = VBlank::IR::Backends::Computer

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

  # What one run of the program printed (its variables at the end of the script), the window as it
  # ended, and what it wrote to its error stream (a refusal, for one).
  Played = Data.define(:variables, :picture, :complaints)

  def test_the_shell_a_player_runs
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(port_without_copy(dir), File.join(dir, "made-up-shell"), console: :gba, err: nil)
      all_in_one = Dir.mktmpdir do |elsewhere|
        Native.new.build_desktop(port(original(elsewhere)), File.join(dir, "all-in-one"), console: :gba, err: nil)
      end
      answer = play(all_in_one, dir, "answer")

      assert_includes marker_rows_of(answer.picture).join, "\xFF\xFF\xFF".b, "the marker is on the picture"

      assert_equal %w[made-up-shell parts], Dir.children(shell).sort
      assert_holds_none_of original_pieces, folder_bytes(shell), "the desktop shell's folder"
      assert_unpacks_keeps_the_pack_and_plays_the_game(shell, dir, answer)
      assert_plays_from_the_kept_pack_with_the_copy_gone(shell, dir, answer)
      assert_asks_again_when_a_new_build_finds_an_older_pack(dir)
      assert_refuses_files_that_are_no_release(shell, dir)
      assert_settings_opens_the_window_menu(shell, dir)
    end
  end

  # AN UNPACKING THAT WORKS A LONG TIME BETWEEN WRITES plays on a thread of its own, so its window
  # keeps showing pictures the whole time. Played on the window's thread, as it was, it showed a
  # picture only every thirtieth time the routine waited for a frame, and this one waits for none
  # as it works. The unpacking part is run as the shell runs it, with --frame-times besides, whose
  # last word counts the pictures handed to the display.
  BUSY_STEPS = 400_000_000 # ShellTests#busy_port's: enough to keep the game as C at work for many frames

  # The pictures the window shows for the menu (its frames before LOAD ROM is chosen and the frames
  # the line shows as chosen) and for the game, at the most: any past these are the unpacking's.
  MENU_AND_GAME_PICTURES = 30

  def test_an_unpacking_shows_pictures_while_it_works_between_writes
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(busy_port(original_nowhere(dir), steps: BUSY_STEPS), File.join(dir, "busy-shell"),
                                             console: :gba, err: nil)
      played = play(shell_exe(shell), dir, "busy", options: [*shell_options(dir, copy: copy_at(dir)), "--frame-times"])
      pictures = played.complaints[/^pictures: (\d+)/, 1].to_i

      assert_operator pictures, :>=, MENU_AND_GAME_PICTURES + 10,
                      "the window showed #{pictures} pictures in all as the unpacking worked:\n#{played.complaints}"
      assert_equal Dir.mktmpdir { |other| busy_port(original(other), steps: 1).data_pack_file }, kept_pack(dir),
                   "the pack is not the all-in-one build's, byte for byte"
      assert_a_window_closed_part_way_keeps_no_pack(shell, dir)
    end
  end

  # The window closed while the unpacking works (SDL takes the signal a system sends a program it
  # asks to end as the window closing): the program ends at once, without waiting for the unpacking,
  # which ends with it, and nothing is left in the pack's folder to make a pack from.
  private def assert_a_window_closed_part_way_keeps_no_pack(shell, dir)
    kept = File.join(dir, "kept-closed")
    pid = Process.spawn(NO_SCREEN_OR_SPEAKER, shell_exe(shell), "--pack-folder", kept, "--shell-menu-keys", File.join(dir, "menu.keys"),
                        "--shell-copy", copy_at(dir), "--scripted-keys", GAME_FRAMES.to_s,
                        "--settings-file", File.join(dir, "none-closed.txt"), in: File::NULL, err: File::NULL, out: File::NULL)
    sleep 0.6
    unpacking = unpackings_running(shell)
    closed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Process.kill("TERM", pid)
    Process.wait(pid)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - closed_at
    sleep 0.2

    refute_empty unpacking, "the window was not closed while the unpacking worked, so this shows nothing"
    assert_operator took, :<, 0.4, "the window waited for the unpacking"
    assert_empty Dir.children(kept), "the shell left these behind in the pack's folder"
    assert_empty unpackings_running(shell), "the unpacking went on with its window closed"
  end

  # The process numbers of this shell's unpacking still running, by the path of its program.
  private def unpackings_running(shell)
    `pgrep -f #{File.join(shell, 'parts', 'unpack-0')}`.split
  end

  # WHAT A PERSON DOES AT THE FILE DIALOG, with nobody there (--shell-picks): closes it with nothing
  # picked, picks a file that is no release, then picks the copy. The window is saved each time the
  # dialog would open (--shell-pick-pictures), and every window opened by the shell or a part of it
  # is written down (VBLANK_WINDOW_LOG, which a part is handed with the rest of the environment).
  def test_one_window_from_the_menu_to_the_game_whatever_is_picked
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(port_without_copy(dir), File.join(dir, "made-up-shell"), console: :gba, err: nil)
      picks = File.join(dir, "picks.txt")
      File.write(picks, "\n#{wrong_copy_at(dir)}\n#{copy_at(dir)}\n")
      windows = File.join(dir, "windows.txt")
      pictures = File.join(dir, "asked")
      played = play(shell_exe(shell), dir, "picked", env: { "VBLANK_WINDOW_LOG" => windows },
                                                     options: [*shell_options(dir), "--shell-picks", picks, "--shell-pick-pictures", pictures])

      assert_equal 1, File.readlines(windows).size, "the shell and its parts opened these windows:\n#{File.read(windows)}"
      assert_equal %w[asked.1.bmp asked.2.bmp asked.3.bmp], Dir.children(dir).grep(/\Aasked\./).sort,
                   "the dialog was not asked for once for each pick"
      (1..3).each { |ask| assert_load_rom_shows_as_chosen(File.binread("#{pictures}.#{ask}.bmp"), "as the dialog opened, time #{ask}") }
      assert_includes played.complaints, "not a release of Made Up that this game knows"
      refute_empty played.variables, "the game did not play after the copy was picked"
      assert_equal all_in_one_pack, kept_pack(dir)
    end
  end

  # The menu's two lines in the window's picture (Original::Shell.menu_program draws LOAD ROM at
  # the screen's middle and SETTINGS twelve rows under it), and its colours as a BMP keeps them,
  # blue first: yellow for the line chosen, white for the line under the cursor.
  LOAD_ROM_ROWS = (240...264)
  SETTINGS_ROWS = (276...300)
  YELLOW = "\x00\xFF\xFF".b
  WHITE = "\xFF\xFF\xFF".b

  private def pixels_on(bmp, rows)
    rows.flat_map do |from_top|
      bmp.byteslice(BMP_HEADER_BYTES + ((BMP_ROWS - 1 - from_top) * BMP_ROW_BYTES), BMP_ROW_BYTES).scan(/.{3}/mn)
    end.uniq
  end

  private def assert_load_rom_shows_as_chosen(bmp, moment)
    assert_includes pixels_on(bmp, LOAD_ROM_ROWS), YELLOW, "LOAD ROM is not shown as chosen #{moment}"
    refute_includes pixels_on(bmp, LOAD_ROM_ROWS), WHITE, "LOAD ROM is still drawn as not chosen #{moment}"
    assert_empty pixels_on(bmp, SETTINGS_ROWS) & [YELLOW, WHITE], "SETTINGS is lit #{moment}"
    assert_operator pixels_on(bmp, SETTINGS_ROWS).size, :>, 1, "SETTINGS is not drawn #{moment}"
  end

  # A script of buttons, a line a frame, with nothing held once its lines run out.
  private def keys_file(dir, name, lines)
    File.join(dir, name).tap { |path| File.write(path, [*lines, *(["0"] * 20)].map { |line| "#{line}\n" }.join) }
  end

  # SETTINGS plays the menu again with the window's menu open. The script it plays with then closes
  # that menu with its first line and chooses LOAD ROM, one line up from SETTINGS, where the cursor
  # was left; had the window's menu been shut, that line would open it, and the A after it would
  # never reach the shell's menu.
  private def assert_settings_opens_the_window_menu(shell, dir)
    FileUtils.rm_rf(File.join(dir, "kept"))
    choose_settings = keys_file(dir, "settings-menu.keys", %w[0 0 128 0 1])
    close_and_load = keys_file(dir, "settings-open.keys", ["0 hotkey:menu", "0", "64", "0", "1"])
    play(shell_exe(shell), dir, "settings", options: ["--pack-folder", File.join(dir, "kept"), "--shell-menu-keys", choose_settings,
                                                      "--shell-settings-keys", close_and_load, "--shell-copy", copy_at(dir)])

    assert_equal all_in_one_pack, kept_pack(dir), "LOAD ROM was chosen after SETTINGS"
  end

  # The game as the window plays it for GAME_FRAMES frames with nothing held.
  private def play(exe, dir, name, options: [], env: {})
    picture = File.join(dir, "#{name}.bmp")
    run = Computer::ProgramRun.run(exe, args: ["--scripted-keys", GAME_FRAMES, "--settings-file", File.join(dir, "none-#{name}.txt"),
                                              "--window-picture", picture, *options],
                                       input: "0\n" * GAME_FRAMES, env: NO_SCREEN_OR_SPEAKER.merge(env), seconds: 240, complaints: true)
    Played.new(variables: Native::HeadlessRun.variables_in(run.printed.lines.map(&:chomp)), picture: File.binread(picture),
               complaints: run.complaints)
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
    assert_equal all_in_one_pack, kept_pack(dir), "the pack is the all-in-one build's, byte for byte"
  end

  private def assert_plays_from_the_kept_pack_with_the_copy_gone(shell, dir, answer)
    File.delete(File.join(dir, "made_up.gba"))
    played = play(shell_exe(shell), dir, "second", options: ["--pack-folder", File.join(dir, "kept")])

    assert_equal answer.variables, played.variables
    assert_equal marker_rows_of(answer.picture), marker_rows_of(played.picture)
  end

  # A pack names the build of the game it was made for: a new build refuses the pack the first one
  # kept, asks for the copy again, and keeps a pack of its own.
  private def assert_asks_again_when_a_new_build_finds_an_older_pack(dir)
    newer = Native.new.build_desktop_shell(port_without_copy(dir, version: "2"), File.join(dir, "made-up-shell-2"), console: :gba, err: nil)
    played = play(shell_exe(newer), dir, "newer", options: shell_options(dir, copy: copy_at(dir)))

    assert_includes played.complaints, "not the data pack this build reads"
    refute_empty played.variables
    assert_equal all_in_one_pack(version: "2"), kept_pack(dir)
  end

  private def assert_refuses_files_that_are_no_release(shell, dir)
    FileUtils.rm_rf(File.join(dir, "kept"))
    { wrong_copy_at(dir) => "not a release of Made Up that this game knows", short_copy_at(dir) => "is 100 bytes" }.each do |file, words|
      refused = assert_raises(Computer::Error) { play(shell_exe(shell), dir, "refused", options: shell_options(dir, copy: file)) }

      assert_includes refused.message, words
      refute File.exist?(File.join(dir, "kept", "data.pack"))
    end
  end
end
