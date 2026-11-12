# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "vblank/live"
require "shell_screen_tests"

# A SHELL'S FIRST SCREEN MADE THE GAME'S OWN, PLAYED AS RUBY (`shell_screen`; ShellScreenTests has
# the port and the answer key). Every picture the shell shows is held to the same screen drawn by a
# plain game, pixel for pixel, and LOAD ROM and SETTINGS do what they do on a screen nobody changed.
#
# The device is headless, and its buttons are set by pass, counted from the first each time the
# shell plays its menu again. A button held on pass n is seen by the pass that draws picture n,
# counting pictures from 0.
class TestShellScreen < Minitest::Test
  include ShellScreenTests

  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session
  Shell = VBlank::Live::Shell
  CHOSEN_FRAMES = VBlank::Original::Shell::CHOSEN_FRAMES

  private def styled_shell(folder) = Shell.from(VBlank::Original::Shell.build(styled_port_without_copy(folder), err: nil))

  # The picture a plain game shows once it is drawing: its third.
  private def picture_of(program)
    device = Headless.new(frames: 3)
    Session.new(program).play(device)
    device.pictures.last.pixels
  end

  # Every picture the shell's menu shows with +buttons+ held, until +frames+ pictures are up. LOAD
  # ROM, if it is chosen, is given no file and no button is held after it.
  private def menu_pictures(shell, folder, buttons:, frames:)
    device = Headless.new(frames: frames, buttons: buttons)
    shell.play(device, folder_path: File.join(folder, "kept"), refused: ->(_) {}, play_game: ->(_) {},
                       choose_copy: -> { buttons.clear && nil })
    device.pictures.map(&:pixels)
  end

  def test_the_first_picture_is_the_screen_a_plain_game_draws
    Dir.mktmpdir do |folder|
      shown = menu_pictures(styled_shell(folder), folder, buttons: {}, frames: 3)

      assert_same_pixels picture_of(first_screen_drawn_plainly), shown.first, "on the first picture"
      assert_same_pixels picture_of(first_screen_drawn_plainly), shown.last, "on the third picture"
    end
  end

  def test_down_moves_the_cursor_to_the_games_own_line_and_on_to_settings
    Dir.mktmpdir do |folder|
      shown = menu_pictures(styled_shell(folder), folder, buttons: { 2 => [:down], 4 => [:down], 6 => [:down] }, frames: 9)

      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE)), shown[3], "after one press of down"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: SETTINGS_LINE)), shown[5], "after two"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: 0)), shown[7], "after three, round to LOAD ROM"
    end
  end

  # The line of the game's own shows as chosen for as long as LOAD ROM does, then its scene is up
  # until B is pressed, and the menu comes back with the cursor on the line it was left on.
  def test_the_credits_line_shows_its_scene_and_comes_back
    Dir.mktmpdir do |folder|
      leave = 4 + CHOSEN_FRAMES + 8
      shown = menu_pictures(styled_shell(folder), folder, buttons: { 2 => [:down], 4 => [:a], leave => [:b] }, frames: leave + 5)

      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE, chosen: true)), shown[6], "with CREDITS chosen"
      assert_same_pixels picture_of(first_screen_drawn_plainly(credits: true)), shown[leave - 1], "with the credits scene up"
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: CREDITS_LINE)), shown.last, "back at the menu"
    end
  end

  # LOAD ROM is still the first line and still asks for the file, shown as chosen as it does.
  def test_load_rom_shows_as_chosen_and_unpacks_the_copy
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: 400, buttons: { 2 => [:a] })
      shown_as_asked = nil
      game_device = Headless.new(frames: 6)
      styled_shell(folder).play(device, folder_path: File.join(folder, "kept"), refused: ->(_) {},
                                        play_game: ->(game) { Session.new(game: game).play(game_device) },
                                        choose_copy: lambda {
                                          shown_as_asked ||= device.pictures.last.pixels
                                          copy_at(folder)
                                        })

      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: 0, chosen: true)), shown_as_asked, "as the file is asked for"
      assert_equal all_in_one_pack, File.binread(File.join(folder, "kept", VBlank::Original::ShellFacts::PACK_FILE))
      assert_equal 6, game_device.pictures.size, "the game did not play after the copy was picked"
    end
  end

  # SETTINGS is the third line here and still opens the settings, and the menu comes back on it.
  def test_settings_under_the_games_own_line_still_opens_the_settings
    Dir.mktmpdir do |folder|
      buttons = { 2 => [:down], 4 => [:down], 6 => [:a] }
      device = Headless.new(frames: 60, buttons: buttons)
      opened_after = []
      styled_shell(folder).play(device, folder_path: File.join(folder, "kept"), choose_copy: -> {}, refused: ->(_) {},
                                        play_game: ->(_) {},
                                        open_settings: lambda {
                                          opened_after << device.pictures.size
                                          buttons.clear
                                        })

      assert_equal 1, opened_after.size
      assert_same_pixels picture_of(first_screen_drawn_plainly(cursor: SETTINGS_LINE)), device.pictures[opened_after.first].pixels,
                         "as the menu comes back from the settings"
    end
  end

  # A game that gives its first screen nothing shows the screen every shell showed before.
  def test_a_game_that_gives_nothing_shows_the_screen_as_it_was
    Dir.mktmpdir do |folder|
      shell = Shell.from(VBlank::Original::Shell.build(port_without_copy(folder), err: nil))
      device = Headless.new(frames: 400, buttons: { 2 => [:down], 4 => [:up], 6 => [:a] })
      shown_as_asked = nil
      shell.play(device, folder_path: File.join(folder, "kept"), refused: ->(_) {}, play_game: ->(_) {},
                         choose_copy: lambda {
                           shown_as_asked ||= device.pictures.last.pixels
                           copy_at(folder)
                         })

      assert_same_pixels picture_of(default_screen_drawn_plainly), device.pictures[0].pixels, "on the first picture"
      assert_same_pixels picture_of(default_screen_drawn_plainly(cursor: 1)), device.pictures[3].pixels, "after down"
      assert_same_pixels picture_of(default_screen_drawn_plainly(cursor: 0)), device.pictures[5].pixels, "after up"
      assert_same_pixels picture_of(default_screen_drawn_plainly(cursor: 0, chosen: true)), shown_as_asked, "as the file is asked for"
    end
  end
end
