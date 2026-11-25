# frozen_string_literal: true

require "test_helper"
require "shell_tests"
require "fileutils"
require "tmpdir"

# A port built as a shell, played as the desktop program. The program holds none of the made-up
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
# The shell has one window from its menu to its game: its parts have none, and send what they draw
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
  # The rows the port's pose stands on (screen rows 100 to 107), drawn from the record of its
  # frame that the unpacking writes.
  POSE_ROWS = ((ShellTests::POSE_TOP * 3)...((ShellTests::POSE_TOP + ShellTests::POSE_SIZE[1]) * 3))

  private def game_rows_of(bmp) = window_rows_of(bmp, MARKER_ROWS) + window_rows_of(bmp, POSE_ROWS)

  private def window_rows_of(bmp, rows)
    rows.map { |from_top| bmp.byteslice(BMP_HEADER_BYTES + ((BMP_ROWS - 1 - from_top) * BMP_ROW_BYTES), BMP_ROW_BYTES) }
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

      assert_includes game_rows_of(answer.picture).join, "\xFF\xFF\xFF".b, "the marker is on the picture"
      refute_empty window_rows_of(answer.picture, POSE_ROWS).join.delete("\0"), "the pose is on the picture"

      assert_equal %w[made-up-shell parts], Dir.children(shell).sort
      assert_holds_none_of original_pieces, folder_bytes(shell), "the desktop shell's folder"
      assert_unpacks_keeps_the_pack_and_plays_the_game(shell, dir, answer)
      assert_plays_from_the_kept_pack_with_the_copy_gone(shell, dir, answer)
      assert_asks_again_when_a_new_build_finds_an_older_pack(dir)
      assert_refuses_files_that_are_no_release(shell, dir)
      assert_settings_opens_the_window_menu(shell, dir)
    end
  end

  # An unpacking that works a long time between writes plays on a thread of its own, so its window
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

  # Timeouts for a check that fails, never reached by one that passes; and how often it looks.
  MOST_SECONDS_UNTIL_UNPACKING_RUNS = 60
  MOST_SECONDS_UNTIL_SHELL_ENDS = 60
  POLL_SECONDS = 0.05

  # The window closed while the unpacking works (SDL takes the signal a system sends a program it
  # asks to end as the window closing): the program ends without waiting for the unpacking to
  # finish, which ends with it, and nothing is left in the pack's folder to make a pack from.
  #
  # Held to what happens, not to the clock. The window is closed once the unpacking is seen running,
  # however long the shell takes to get there: a fixed wait before closing it missed the unpacking
  # on a busy machine, where the shell had not yet got through its menu. And the unpacking is paused
  # before the window closes, so it can never finish: a shell that waited for it would never end,
  # where a time bound on the shell's end could be broken by a busy machine alone. The shell stops
  # the paused unpacking as it would a working one (a paused program still takes the stop) and waits
  # for it to end before it ends itself (rg_sdl.c's quit), so the unpacking is gone once the shell is.
  private def assert_a_window_closed_part_way_keeps_no_pack(shell, dir)
    kept = File.join(dir, "kept-closed")
    pid = Process.spawn(NO_SCREEN_OR_SPEAKER, shell_exe(shell), "--pack-folder", kept, "--shell-menu-keys", File.join(dir, "menu.keys"),
                        "--shell-copy", copy_at(dir), "--scripted-keys", GAME_FRAMES.to_s,
                        "--settings-file", File.join(dir, "none-closed.txt"), in: File::NULL, err: File::NULL, out: File::NULL)
    unpacking = unpacking_once_running(shell, pid)
    begin
      refute_empty unpacking, "the unpacking did not start in #{MOST_SECONDS_UNTIL_UNPACKING_RUNS} s, so this shows nothing"
      begin
        unpacking.each { |part| Process.kill("STOP", Integer(part)) }
      rescue Errno::ESRCH
        flunk "the unpacking ended before the window was closed, so this shows nothing"
      end
      Process.kill("TERM", pid)

      assert poll_until(MOST_SECONDS_UNTIL_SHELL_ENDS) { Process.wait(pid, Process::WNOHANG) }, "the window waited for the unpacking"
      assert_empty Dir.children(kept), "the shell left these behind in the pack's folder"
      assert_empty unpackings_running(shell), "the unpacking went on with its window closed"
    ensure
      stop_left_running(pid, unpackings_running(shell))
    end
  end

  # The process numbers of this shell's unpacking once it is running; empty if the shell ended
  # first (it is then waited for) or MOST_SECONDS_UNTIL_UNPACKING_RUNS went by.
  private def unpacking_once_running(shell, pid)
    found = poll_until(MOST_SECONDS_UNTIL_UNPACKING_RUNS) do
      running = unpackings_running(shell)
      running.empty? ? Process.wait(pid, Process::WNOHANG) && [] : running
    end
    found || []
  end

  # The block's first answer that is not nil or false, asked every POLL_SECONDS; nil once +seconds+
  # go by without one.
  private def poll_until(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      answer = yield
      return answer if answer
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep POLL_SECONDS
    end
  end

  # Kills what a failed check left running: its unpacking +parts+, and the shell +pid+ unless it was
  # waited for already (its number may then be another program's), waited for.
  private def stop_left_running(pid, parts)
    parts.each do |part|
      Process.kill("KILL", Integer(part))
    rescue Errno::ESRCH
      nil
    end
    return if Process.wait(pid, Process::WNOHANG)

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  # The process numbers of this shell's unpacking still running, by the path of its program.
  private def unpackings_running(shell)
    `pgrep -f #{File.join(shell, 'parts', 'unpack-0')}`.split
  end

  # What a person does at the file dialog, with nobody there (--shell-picks): closes it with nothing
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
      told = File.join(dir, "told.txt")
      played = play(shell_exe(shell), dir, "picked", env: { "VBLANK_WINDOW_LOG" => windows },
                                                     options: [*shell_options(dir), "--shell-picks", picks, "--shell-pick-pictures", pictures,
                                                               "--shell-told", told])

      # The file refused is told in a box the window draws, which nothing waits for: the menu
      # played on under it, or this run would not have got to its third pick.
      assert_equal 1, File.readlines(told).size, "the shell put these in a box:\n#{File.read(told)}"
      assert_match "not a release of Made Up that this game knows", File.read(told)
      assert_equal 1, File.readlines(windows).size, "the shell and its parts opened these windows:\n#{File.read(windows)}"
      assert_equal %w[asked.1.bmp asked.2.bmp asked.3.bmp], Dir.children(dir).grep(/\Aasked\./).sort,
                   "the dialog was not asked for once for each pick"
      (1..3).each { |ask| assert_load_rom_shows_as_chosen(File.binread("#{pictures}.#{ask}.bmp"), "as the dialog opened, time #{ask}") }
      assert_empty grays_on(File.binread("#{pictures}.1.bmp"), READ_AGAIN_ROWS), "a first start says the data must be read again"
      assert_includes played.complaints, "not a release of Made Up that this game knows"
      refute_empty played.variables, "the game did not play after the copy was picked"
      assert_equal all_in_one_pack, kept_pack(dir)
    end
  end

  # A pack an older build kept is routine, and never a BOX. A port grows a part at a time and each
  # part changes its pack, so a player who takes a new build starts it over the old build's pack: one
  # of another version, or of another size. The shell was started over one by a person, put up a box
  # of the system's as it started, and the box could not be answered: the program never came back.
  #
  # Started over either pack, the shell tells the player nothing in a box (--shell-told gets a line
  # for each box, and there is none), shows its menu saying the data must be read again, takes the
  # copy as on a first start, and writes its own pack over the old one. Why the pack was not read
  # goes on the error stream, naming the original the player owns and not this program.
  def test_a_pack_kept_by_an_older_build_starts_at_the_menu_with_no_box
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(port_without_copy(dir), File.join(dir, "made-up-shell"), console: :gba, err: nil)
      { "another version" => all_in_one_pack(version: "0"), "another size" => all_in_one_pack.byteslice(0, 100) }.each do |which, older|
        FileUtils.rm_rf(File.join(dir, "kept"))
        FileUtils.mkdir_p(File.join(dir, "kept"))
        File.binwrite(File.join(dir, "kept", "data.pack"), older)
        picks = File.join(dir, "picks.txt")
        File.write(picks, "#{copy_at(dir)}\n")
        told = File.join(dir, "told-#{which.tr(' ', '-')}.txt")
        pictures = File.join(dir, "over-#{which.tr(' ', '-')}")
        played = play(shell_exe(shell), dir, "over", options: [*shell_options(dir), "--shell-picks", picks, "--shell-pick-pictures", pictures,
                                                                "--shell-told", told])

        refute_path_exists told, "a pack of #{which} was told to the player in a box"
        assert_says_the_data_must_be_read_again File.binread("#{pictures}.1.bmp"), "over a pack of #{which}"
        assert_includes played.complaints, "your copy of Made Up", "the error stream does not name the original (#{which})"
        refute_empty played.variables, "the game did not play after the copy was picked over a pack of #{which}"
        assert_equal all_in_one_pack, kept_pack(dir), "the pack of #{which} was not replaced"
      end
    end
  end

  # The rows of the window under the menu's lines, where the menu says the data must be read again
  # (screen rows 108 to 140), in gray: a BMP's gray has its three bytes alike, neither black nor white.
  READ_AGAIN_ROWS = (324...420)

  private def grays_on(bmp, rows) = pixels_on(bmp, rows).select { |pixel| pixel.bytes.uniq.size == 1 && pixel.getbyte(0).between?(0x30, 0xC0) }

  private def assert_says_the_data_must_be_read_again(bmp, moment)
    refute_empty grays_on(bmp, READ_AGAIN_ROWS), "the menu does not say the data must be read again #{moment}"
  end

  # The menu's two lines in the window's picture (Original::Shell.menu_program draws LOAD ROM at
  # the screen's middle and settings twelve rows under it), and its colours as a BMP keeps them,
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
  # that menu with its first line and chooses LOAD ROM, one line up from settings, where the cursor
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
    assert_equal game_rows_of(answer.picture), game_rows_of(played.picture)
    assert_equal all_in_one_pack, kept_pack(dir), "the pack is the all-in-one build's, byte for byte"
  end

  private def assert_plays_from_the_kept_pack_with_the_copy_gone(shell, dir, answer)
    File.delete(File.join(dir, "made_up.gba"))
    played = play(shell_exe(shell), dir, "second", options: ["--pack-folder", File.join(dir, "kept")])

    assert_equal answer.variables, played.variables
    assert_equal game_rows_of(answer.picture), game_rows_of(played.picture)
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
