# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "vblank/live"
require "shell_screen_tests"

# A SHELL'S FIRST SCREEN MADE THE GAME'S OWN, IN THE DESKTOP PROGRAM (`shell_screen`;
# ShellScreenTests has the port and the answer key). Like test_native_shell.rb it builds with SDL,
# so it is loaded only under SDL=1.
#
# The first screen is the shell's menu part, a program of its own with no window, which sends
# every picture it draws down its standard output and reads the buttons for each frame from its
# standard input (runtime/rg_sdl.c, "A PART OF A SHELL PLAYS WITH NO WINDOW"). So the first test
# plays that part as the shell's window does and holds every picture it sends to the same screen
# drawn by a plain game, pixel for pixel. The second plays the whole shell in its window and
# picks a copy, with the game's own line visited on the way.
class TestNativeShellScreen < Minitest::Test
  include ShellScreenTests

  Native = VBlank::IR::Backends::Native
  Computer = VBlank::IR::Backends::Computer

  NO_SCREEN_OR_SPEAKER = { "SDL_VIDEO_DRIVER" => "dummy", "SDL_AUDIO_DRIVER" => "dummy" }.freeze
  CHOSEN_FRAMES = VBlank::Original::Shell::CHOSEN_FRAMES

  # A button as a script's line holds it: a bit each, as the windowless program reads them.
  A = 1
  B = 2
  UP = 64
  DOWN = 128

  # The picture a plain game shows once it is drawing, as the runtime written in Ruby draws it.
  private def picture_of(program)
    device = VBlank::Live::Headless.new(frames: 3)
    VBlank::Live::Session.new(program).play(device)
    device.pictures.last.pixels
  end

  # Every picture the menu part of +shell+ sends, played with +buttons+ (a frame's number, from
  # 1, to the buttons held for the frame after that picture) for +frames+ pictures.
  private def menu_part_pictures(shell, dir, buttons:, frames:)
    start = File.join(dir, "menu.start")
    File.binwrite(start, VBlank::Original::ShellFacts.menu_start_file(0))
    pictures = []
    Open3.popen2(NO_SCREEN_OR_SPEAKER, File.join(shell, "parts", "menu"), "--part", File.join(dir, "menu.answer"),
                 "--data-pack", start) do |to_part, from_part, _waiting|
      from_part.binmode
      frames.times do |frame|
        size = from_part.read(4) or break
        width, height = size.unpack("v2")
        pictures << from_part.read(2 * width * height).unpack("v*")
        to_part.puts(buttons.fetch(frame + 1, 0))
        to_part.flush
      end
      to_part.close
    end
    pictures
  end

  def test_the_menu_part_draws_the_screen_a_plain_game_draws
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(styled_port_without_copy(dir), File.join(dir, "styled-shell"), console: :gba, err: nil)
      leave = 4 + CHOSEN_FRAMES + 8
      shown = menu_part_pictures(shell, dir, buttons: { 2 => DOWN, 4 => A, leave => B, leave + 4 => DOWN }, frames: leave + 8)

      assert_same_pixels picture_of(first_screen_drawn_plainly), shown[0], "on the first picture"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE)), shown[3], "after down"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE, chosen: true)), shown[6], "with CREDITS chosen"
      assert_same_pixels picture_of(first_screen_drawn_plainly(credits: true)), shown[leave - 1], "with the credits scene up"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE)), shown[leave + 2], "back at the menu"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: SETTINGS_LINE)), shown.last, "after down to SETTINGS"
    end
  end

  # The whole shell in its window, as a player goes: down to CREDITS, its scene and back, up to
  # LOAD ROM, and the copy picked (--shell-picks). One window, the pack kept, and the game plays.
  def test_load_rom_still_starts_the_game_after_a_visit_to_the_games_own_line
    Dir.mktmpdir do |dir|
      shell = Native.new.build_desktop_shell(styled_port_without_copy(dir), File.join(dir, "styled-shell"), console: :gba, err: nil)
      keys = File.join(dir, "menu.keys")
      visit = [0, 0, DOWN, 0, A, *[0] * (CHOSEN_FRAMES + 6), B, 0, 0, UP, 0, A]
      File.write(keys, [*visit, *[0] * 30].map { |held| "#{held}\n" }.join)
      picks = File.join(dir, "picks.txt")
      File.write(picks, "#{copy_at(dir)}\n")
      windows = File.join(dir, "windows.txt")
      run = Computer::ProgramRun.run(File.join(shell, "styled-shell"),
                                     args: ["--scripted-keys", 8, "--settings-file", File.join(dir, "none.txt"),
                                            "--pack-folder", File.join(dir, "kept"), "--shell-menu-keys", keys, "--shell-picks", picks],
                                     input: "0\n" * 8, env: NO_SCREEN_OR_SPEAKER.merge("VBLANK_WINDOW_LOG" => windows), seconds: 240,
                                     complaints: true)

      assert_equal 1, File.readlines(windows).size
      assert_equal all_in_one_pack, File.binread(File.join(dir, "kept", "data.pack"))
      refute_empty Native::HeadlessRun.variables_in(run.printed.lines.map(&:chomp)), "the game did not play after the copy was picked"
    end
  end
end
