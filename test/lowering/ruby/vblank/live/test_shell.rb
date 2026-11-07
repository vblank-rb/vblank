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
  # for nothing), and the game, once it plays, for GAME_PASSES passes. What happened, by name.
  Played = Data.define(:game_pictures, :refusals, :times_asked)

  private def play_shell(shell, folder, picked:, buttons: CHOOSE_LOAD_ROM, menu_frames: 400)
    refusals = []
    asked = 0
    game_device = Headless.new(frames: GAME_PASSES)
    shell.play(Headless.new(frames: menu_frames, buttons: buttons), folder_path: File.join(folder, "kept"),
                                                                    choose_copy: lambda {
                                                                      asked += 1
                                                                      picked
                                                                    }, refused: ->(words) { refusals << words },
                                                                    play_game: ->(game) { Session.new(game: game).play(game_device) })
    Played.new(game_pictures: game_device.pictures.map(&:pixels), refusals: refusals, times_asked: asked)
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

  # A pack names the build of the game it was made for, so a new build refuses the pack an older
  # one kept, asks for the copy again, and keeps the new build's pack.
  def test_a_new_build_of_the_port_asks_for_the_copy_again
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))
      played = play_shell(shell(folder, version: "2"), folder, picked: copy_at(folder))

      assert_equal 1, played.times_asked
      assert_match "not the data pack this build reads", played.refusals.first
      assert_equal all_in_one_pack(version: "2"), kept_pack(folder)
    end
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

  def test_settings_on_the_menu_opens_the_settings_then_shows_the_menu_again
    Dir.mktmpdir do |folder|
      buttons = { 2 => [:down], 4 => [:a] }
      opened = 0
      shell(folder).play(Headless.new(frames: 400, buttons: buttons), folder_path: File.join(folder, "kept"),
                                                                       choose_copy: -> { copy_at(folder) }, refused: ->(_) {},
                                                                       open_settings: lambda {
                                                                         opened += 1
                                                                         buttons.replace(CHOOSE_LOAD_ROM)
                                                                       },
                                                                       play_game: ->(_) {})

      assert_equal 1, opened
      assert File.exist?(File.join(folder, "kept", PACK_FILE))
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
