# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "vblank/live"
require "shell_tests"

# A PORT BUILT AS A SHELL, PLAYED AS RUBY. The shell holds none of the made-up original's data
# (MadeUpOriginal, made_up_original.rb's). Started with no pack kept, it shows its menu; LOAD ROM
# takes the file the player picks, checks it is a release the game reads, unpacks it with the
# game's own routine, keeps the pack in the game's folder and plays the game. The next start plays
# the game from the kept pack and never reads the copy.
#
# The answer key is the same game built all-in-one from the same copy, played live the same way,
# and the pack that build makes, which the shell's must be byte for byte.
#
# The device is headless, and its buttons are set by pass: each play the shell starts (the menu,
# the unpacking, the game) counts its passes from the first again, so A held on pass 2 chooses the
# menu's first line, LOAD ROM, every time the menu plays.
class TestShell < Minitest::Test
  include ShellTests

  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session
  Shell = VBlank::Live::Shell
  PACK_FILE = VBlank::Original::ShellFacts::PACK_FILE

  # How many passes of the game each test watches.
  GAME_PASSES = 6
  CHOOSE_LOAD_ROM = { 2 => [:a] }.freeze

  # The pictures the all-in-one build of the port shows over GAME_PASSES passes.
  private def all_in_one_pictures
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: GAME_PASSES)
      Session.new(port(original(folder)).checked_program(err: nil, for_computer: true)).play(device)
      device.pictures.map(&:pixels)
    end
  end

  # The shell of the port, as Ruby, built on a machine with no copy.
  private def shell(folder, version: "1")
    VBlank::Live::Shell.from(VBlank::Original::Shell.build(port_without_copy(folder, version: version), err: nil))
  end

  # The shell played once: the menu with +buttons+ held, LOAD ROM picking +picked+ (a path, or nil
  # for nothing), and the game, once it plays, for GAME_PASSES passes. What happened, by name:
  # +refusals+ are what the player was told, +kept_pack_refusals+ what whoever made the build was
  # told of a kept pack not read, and +menu_pictures+ every picture before the game's.
  Played = Data.define(:game_pictures, :refusals, :times_asked, :kept_pack_refusals, :menu_pictures)

  private def play_shell(shell, folder, picked:, buttons: CHOOSE_LOAD_ROM, menu_frames: 400)
    refusals = []
    kept_pack_refusals = []
    asked = 0
    game_device = Headless.new(frames: GAME_PASSES)
    menu_device = Headless.new(frames: menu_frames, buttons: buttons)
    shell.play(menu_device, folder_path: File.join(folder, "kept"),
                            choose_copy: lambda {
                              asked += 1
                              picked
                            }, refused: ->(words) { refusals << words },
                            kept_pack_refused: ->(words) { kept_pack_refusals << words },
                            play_game: ->(game) { Session.new(game: game).play(game_device) })
    Played.new(game_pictures: game_device.pictures.map(&:pixels), refusals: refusals, times_asked: asked,
               kept_pack_refusals: kept_pack_refusals, menu_pictures: menu_device.pictures)
  end

  private def kept_pack(folder) = File.binread(File.join(folder, "kept", PACK_FILE))

  def test_the_first_start_unpacks_the_copy_keeps_the_pack_and_plays_the_game
    Dir.mktmpdir do |folder|
      played = play_shell(shell(folder), folder, picked: copy_at(folder))

      assert_equal 1, played.times_asked
      assert_empty played.refusals
      assert_equal GAME_PASSES, played.game_pictures.size
      assert_equal all_in_one_pictures, played.game_pictures
    end
  end

  def test_the_pack_the_shell_keeps_is_the_all_in_one_builds_byte_for_byte
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))

      assert_equal all_in_one_pack, kept_pack(folder)
    end
  end

  # A port whose original has two releases, the data at other places in each: one shell unpacks
  # either copy, and keeps the pack the all-in-one build from that copy makes.
  def test_a_shell_unpacks_either_release_of_an_original_with_two_releases
    [["US", COPY], ["EU", COPY_EU]].each do |name, bytes|
      Dir.mktmpdir do |folder|
        shell = VBlank::Live::Shell.from(VBlank::Original::Shell.build(two_release_port(two_release_original(folder)), err: nil))
        picked = File.join(folder, "picked.gba").tap { |path| File.binwrite(path, bytes) }
        played = play_shell(shell, folder, picked: picked)

        assert_empty played.refusals, name
        assert_equal Dir.mktmpdir { |other| two_release_port(two_release_original(other, copy: bytes)).data_pack_file }, kept_pack(folder), name
      end
    end
  end

  private def two_release_port(from)
    place_slots = ->(slots) { two_release_slots(slots) }
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: "1") { |slots| place_slots.call(slots) }
      image :wall_a, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      heights = table :heights, pack[:heights]
      game_loop do
        draw_rect_at heights[0] * 4, 40, 4, 4, :white
      end
    end
  end

  def test_the_next_start_plays_from_the_kept_pack_with_the_copy_gone
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))
      File.delete(File.join(folder, "made_up.gba"))
      played = play_shell(shell(folder), folder, picked: nil)

      refute File.exist?(File.join(folder, "made_up.gba"))
      assert_equal 0, played.times_asked
      assert_equal all_in_one_pictures, played.game_pictures
    end
  end

  # A PACK AN OLDER BUILD KEPT IS ROUTINE: a port grows a part at a time, and each part changes
  # its pack. A new build does not read it, tells the player nothing went wrong (no refusal), says
  # on its menu that the data must be read again from the copy of the original, by the original's
  # own title, asks for the copy as on a first start, and writes its pack over the old one.
  def test_a_new_build_of_the_port_asks_for_the_copy_again
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))
      played = play_shell(shell(folder, version: "2"), folder, picked: copy_at(folder))

      assert_equal 1, played.times_asked
      assert_empty played.refusals, "a pack kept by an older build was told to the player as a refusal"
      assert_match "not the data pack this build reads", played.kept_pack_refusals.first
      assert_match "your copy of Made Up", played.kept_pack_refusals.first
      assert_equal [GRAY], colors_on(played.menu_pictures.first, READ_AGAIN_ROWS), "the menu does not say the data must be read again"
      assert_equal all_in_one_pack(version: "2"), kept_pack(folder)
    end
  end

  # A kept pack of another size (the port gained a slot) is the same: the menu, and no refusal.
  def test_a_kept_pack_of_another_size_starts_at_the_menu_and_is_replaced
    Dir.mktmpdir do |folder|
      FileUtils.mkdir_p(File.join(folder, "kept"))
      File.binwrite(File.join(folder, "kept", PACK_FILE), all_in_one_pack.byteslice(0, 100))
      played = play_shell(shell(folder), folder, picked: copy_at(folder))

      assert_empty played.refusals
      assert_equal [GRAY], colors_on(played.menu_pictures.first, READ_AGAIN_ROWS)
      assert_equal all_in_one_pictures, played.game_pictures
      assert_equal all_in_one_pack, kept_pack(folder)
    end
  end

  # A first start, with no pack kept, says nothing of reading the data again.
  def test_a_first_start_does_not_say_the_data_must_be_read_again
    Dir.mktmpdir do |folder|
      played = play_shell(shell(folder), folder, picked: copy_at(folder))

      assert_empty colors_on(played.menu_pictures.first, READ_AGAIN_ROWS)
    end
  end

  # What the menu says of a pack to read again is the original's title, not this program's, and
  # fits the screen a row of words at a time.
  def test_the_menu_names_the_original_the_player_owns
    sentence = VBlank::Original::Shell.read_again_sentence("The Made Up Original")
    rows = VBlank::Original::Shell.read_again_rows(sentence.upcase, 120) { |words| words.length * 6 }

    assert_match "Load your copy of The Made Up Original.", sentence
    assert_equal sentence.upcase, rows.join(" ")
    assert_operator rows.map(&:length).max, :<=, 20
    assert_operator rows.size, :>, 1
  end

  def test_a_copy_of_the_right_size_that_is_no_release_is_refused
    Dir.mktmpdir do |folder|
      played = play_shell(shell(folder), folder, picked: wrong_copy_at(folder), menu_frames: 40)

      assert_match "not a release of Made Up that this game knows", played.refusals.first
      assert_empty played.game_pictures
      refute File.exist?(File.join(folder, "kept", PACK_FILE))
    end
  end

  def test_a_file_no_release_is_the_size_of_is_refused_naming_the_size
    Dir.mktmpdir do |folder|
      played = play_shell(shell(folder), folder, picked: short_copy_at(folder), menu_frames: 40)

      assert_match "is 100 bytes", played.refusals.first
      assert_empty played.game_pictures
    end
  end

  # The menu comes back with SETTINGS still under the cursor, so LOAD ROM is one line up from it.
  def test_settings_on_the_menu_opens_the_settings_then_shows_the_menu_again
    Dir.mktmpdir do |folder|
      buttons = { 2 => [:down], 4 => [:a] }
      opened = 0
      shell(folder).play(Headless.new(frames: 400, buttons: buttons), folder_path: File.join(folder, "kept"),
                                                                       choose_copy: -> { copy_at(folder) }, refused: ->(_) {},
                                                                       open_settings: lambda {
                                                                         opened += 1
                                                                         buttons.replace({ 2 => [:up], 4 => [:a] })
                                                                       },
                                                                       play_game: ->(_) {})

      assert_equal 1, opened
      assert File.exist?(File.join(folder, "kept", PACK_FILE))
    end
  end

  # THE MENU'S TWO LINES, as rows of the picture (Original::Shell.menu_program puts LOAD ROM at the
  # screen's middle and SETTINGS twelve rows under it), and the colours a line is drawn in: gray,
  # white under the cursor, and yellow once it is chosen.
  LOAD_ROM_ROWS = (80...88)
  SETTINGS_ROWS = (92...100)
  # The rows under the menu's lines, where it says the game's data must be read again.
  READ_AGAIN_ROWS = (104...160)
  GRAY, WHITE, YELLOW = %i[gray white yellow].map { |name| Color.resolve(name) }

  # The colours of the words on +rows+ of +picture+ (a Headless::Picture), black left out.
  private def colors_on(picture, rows)
    rows.flat_map { |row| picture.pixels[row * picture.width, picture.width] }.uniq - [Color.resolve(:black)]
  end

  # The line chosen shows as chosen before anything else happens: the picture up as the file is
  # asked for has LOAD ROM in yellow, and it was up for several frames by then.
  def test_the_chosen_line_shows_as_chosen_before_the_file_is_asked_for
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: 400, buttons: CHOOSE_LOAD_ROM)
      shown_as_asked = nil
      shell(folder).play(device, folder_path: File.join(folder, "kept"), refused: ->(_) {}, play_game: ->(_) {},
                                 choose_copy: lambda {
                                   shown_as_asked ||= device.pictures.dup
                                   copy_at(folder)
                                 })
      chosen = shown_as_asked.select { |picture| colors_on(picture, LOAD_ROM_ROWS) == [YELLOW] }

      assert_equal [YELLOW], colors_on(shown_as_asked.last, LOAD_ROM_ROWS), "LOAD ROM is not shown as chosen"
      assert_equal [GRAY], colors_on(shown_as_asked.last, SETTINGS_ROWS)
      assert_operator chosen.size, :>=, 6, "the chosen line was up for #{chosen.size} frames"
      assert_equal [WHITE], colors_on(shown_as_asked.first, LOAD_ROM_ROWS), "the menu opens with LOAD ROM under the cursor"
    end
  end

  # One device from the menu to the unpacking's last picture: the menu, the chooser and the
  # progress bar are all the one window's, and the game is handed to play on after them.
  def test_the_menu_and_the_unpacking_show_on_the_one_device
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: 400, buttons: CHOOSE_LOAD_ROM)
      shell(folder).play(device, folder_path: File.join(folder, "kept"), choose_copy: -> { copy_at(folder) }, refused: ->(_) {},
                                 play_game: ->(_) {})
      bar = device.pictures.last
      middle = (bar.height / 2 * bar.width) + (bar.width / 2)

      assert_equal [WHITE], colors_on(device.pictures.first, LOAD_ROM_ROWS)
      assert_equal WHITE, bar.pixels[middle], "the unpacking's bar is not on the device the menu was on"
    end
  end

  # A chooser closed with nothing picked leaves the menu up as it was: the same line under the
  # cursor, no longer shown as chosen, and A asks for the file again.
  def test_a_chooser_cancelled_shows_the_menu_again_on_the_same_line
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: 60, buttons: CHOOSE_LOAD_ROM)
      asked_after = []
      shell(folder).play(device, folder_path: File.join(folder, "kept"), refused: ->(_) {}, play_game: ->(_) {},
                                 choose_copy: lambda {
                                   asked_after << device.pictures.size
                                   nil
                                 })
      back = device.pictures[asked_after.first]

      assert_operator asked_after.size, :>=, 2, "the menu did not come back to ask again"
      assert_equal [WHITE], colors_on(back, LOAD_ROM_ROWS), "the menu came back with LOAD ROM not under the cursor"
      assert_equal [GRAY], colors_on(back, SETTINGS_ROWS)
    end
  end

  # SETTINGS closed again leaves the cursor on SETTINGS: with nothing moved, A opens them again.
  def test_the_menu_comes_back_from_settings_with_settings_under_the_cursor
    Dir.mktmpdir do |folder|
      buttons = { 2 => [:down], 4 => [:a] }
      device = Headless.new(frames: 60, buttons: buttons)
      opened_after = []
      shell(folder).play(device, folder_path: File.join(folder, "kept"), choose_copy: -> {}, refused: ->(_) {}, play_game: ->(_) {},
                                 open_settings: lambda {
                                   opened_after << device.pictures.size
                                   buttons.replace({ 3 => [:a] })
                                 })
      back = device.pictures[opened_after.first]

      assert_equal [WHITE], colors_on(back, SETTINGS_ROWS), "the menu came back with SETTINGS not under the cursor"
      assert_equal [GRAY], colors_on(back, LOAD_ROM_ROWS)
      assert_operator opened_after.size, :>=, 2, "A on the line the cursor came back to did not open the settings again"
    end
  end

  # A file refused hands its words over and shows the menu again, LOAD ROM under the cursor.
  def test_a_file_refused_shows_the_menu_again
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: 60, buttons: CHOOSE_LOAD_ROM)
      refused_after = []
      shell(folder).play(device, folder_path: File.join(folder, "kept"), choose_copy: -> { wrong_copy_at(folder) },
                                 refused: ->(_) { refused_after << device.pictures.size }, play_game: ->(_) {})
      back = device.pictures[refused_after.first]

      assert_operator refused_after.size, :>=, 2, "the menu did not come back after the file was refused"
      assert_equal [WHITE], colors_on(back, LOAD_ROM_ROWS)
    end
  end

  # The unpacking shows how far it has got: its last picture is the whole bar, lit.
  def test_the_unpacking_shows_a_full_progress_bar_at_its_end
    Dir.mktmpdir do |folder|
      device = Headless.new(frames: 400)
      shell(folder).pack_from_copy("made_up.gba", COPY, device)
      picture = device.pictures.last
      middle = (picture.height / 2 * picture.width) + (picture.width / 2)

      assert_equal Color.resolve(:white), picture.pixels[middle]
      assert_equal Color.resolve(:white), picture.pixels[middle + (picture.width / 2) - 17]
    end
  end

  # AN UNPACKING THAT WORKS A LONG TIME BETWEEN WRITES (a port rendering music before it writes a
  # byte) plays away from the window, so the window keeps showing frames the whole time, and the
  # pack it makes is still the all-in-one build's byte for byte. Played on the window, as it was, the
  # routine showed a frame only when it waited for one, and this one waits for none as it works.
  BUSY_STEPS = 3_000_000 # ShellTests#busy_port's, enough to keep the Ruby runtime at work for many frames

  def test_the_window_keeps_showing_frames_while_the_unpacking_works_between_writes
    Dir.mktmpdir do |folder|
      shell = Shell.from(VBlank::Original::Shell.build(busy_port(original_nowhere(folder), steps: BUSY_STEPS), err: nil))
      device = Headless.new(frames: 100_000)
      pack = shell.pack_from_copy("made_up.gba", COPY, device)

      assert_equal Dir.mktmpdir { |other| busy_port(original(other), steps: 1).data_pack_file }, pack
      assert_operator device.pictures.size, :>=, 10, "the window showed a frame only now and then as the unpacking worked"
    end
  end

  # An unpacking that finds the wrong format where its routine reads is refused in a player's words,
  # from the unpacking's own Ractor as from the window.
  def test_an_unpacking_that_goes_wrong_is_refused
    Dir.mktmpdir do |folder|
      from = original_nowhere(folder)
      wrong = VBlank.game("MADE UP", consoles: %i[gba]) do
        screen :bitmap
        pack = data_pack(from: from, version: "1") do |slots|
          slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
          slots.fill_from_copy { |copy, into| copy.unpack_lz77 at: RLE_AT, into: into[:heights] }
        end
        heights = table :heights, pack[:heights]
        game_loop { draw_rect_at heights[0] * 4, 40, 4, 4, :white }
      end
      shell = Shell.from(VBlank::Original::Shell.build(wrong, err: nil))
      refused = assert_raises(Shell::Refused) { shell.pack_from_copy("made_up.gba", COPY, Headless.new(frames: 400)) }

      assert_match "made_up.gba", refused.message
    end
  end

  # The window closed part way: the shell keeps no pack, and gives up at once rather than waiting
  # for the unpacking to finish its work.
  def test_a_window_closed_while_the_unpacking_works_keeps_no_pack
    Dir.mktmpdir do |folder|
      shell = Shell.from(VBlank::Original::Shell.build(busy_port(original_nowhere(folder), steps: BUSY_STEPS), err: nil))
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      pack = shell.pack_from_copy("made_up.gba", COPY, Headless.new(frames: 2))

      assert_nil pack
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - began, :<, 0.5, "the window waited for the unpacking"
    end
  end

  # A Ruby with none of the settings that would let it find this library or its gems, in SDL's
  # window that shows nothing (as test_ruby_script.rb plays a script).
  ALONE = { "SDL_VIDEODRIVER" => "dummy", "SDL_AUDIODRIVER" => "dummy", "RUBYOPT" => nil, "RUBYLIB" => nil,
            "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil, "BUNDLER_VERSION" => nil, "RUBY_YJIT_ENABLE" => nil }.freeze

  # The shell written out as one Ruby file carries its menu, its unpacking and the pack's checks,
  # and plays the game from the pack kept in its folder; it holds none of the original's bytes.
  def test_a_shell_written_as_one_ruby_file_plays_from_the_kept_pack
    flunk "SDL3 is not installed: #{VBlank::Live::SDL::INSTALL_LINE}" unless VBlank::Live::SDL.available?

    Dir.mktmpdir do |folder|
      path = VBlank::IR::Backends::Ruby.new.build_script(port_without_copy(folder), File.join(folder, "port-ruby.rb"),
                                                          console: :gba, err: StringIO.new, shell: true)
      kept = File.join(folder, "kept")
      FileUtils.mkdir_p(kept)
      File.binwrite(File.join(kept, PACK_FILE), all_in_one_pack)
      played, status = Open3.capture2e(ALONE, RbConfig.ruby, path, "--pictures", "3", "--pack-folder", kept,
                                       "--settings-file", File.join(folder, "settings.txt"), chdir: folder)

      assert status.success?, played
      assert_match(/3 frames in/, played)
      assert_holds_none_of original_pieces, File.binread(path), "the Ruby script"
    end
  end
end
