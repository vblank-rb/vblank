# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "vblank/live"
require "all/vblank/builder/test_data_packs"

# A PORT BUILT AS A SHELL, PLAYED AS RUBY. The shell holds none of the made-up original's data
# (MadeUpOriginal, test_data_packs.rb's). Started with no pack kept, it shows its menu; LOAD ROM
# takes the file the player picks, checks it is a release the game reads, unpacks it with the
# game's own routine, keeps the pack in the game's folder and plays the game. The next start plays
# the game from the kept pack and never reads the copy.
#
# The answer key is the same game built all-in-one from the same copy, played live the same way,
# and the pack the all-in-one build makes, which the shell's must be byte for byte.
#
# The device is headless, and its buttons are set by pass: each play the shell starts (the menu,
# the unpacking, the game) counts its passes from the first again, so A held on pass 2 chooses the
# menu's first line, LOAD ROM, every time the menu plays.
class TestShell < Minitest::Test
  include MadeUpOriginal

  Headless = VBlank::Live::Headless
  Session = VBlank::Live::Session
  Shell = VBlank::Live::Shell

  # How many passes of the game each test watches.
  GAME_PASSES = 6
  CHOOSE_LOAD_ROM = { 2 => [:a] }.freeze

  # The made-up port: the colours copied as they are, the tiles and the heights unpacked by its
  # routine, laid out as a background with a marker placed by the heights. +version+ is the build
  # the pack names.
  private def port(from, version: "1")
    VBlank.game("MADE UP", consoles: %i[gba]) do
      screen :bitmap
      clear_screen :black
      pack = data_pack(from: from, version: version) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      image :wall_a, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(0)
      image :wall_b, width: 8, height: 8, colors: pack[:palette], places: pack[:walls].tile(1)
      tiles :walls, 0 => :wall_a, 1 => :wall_b
      background :room, tiles: :walls, map: [[0, 1, 0, 1], [1, 0, 1, 0]]
      heights = table :heights, pack[:heights]
      step = var :step, 0
      game_loop do
        draw_rect_at heights[step] * 4, 40, 4, 4, :white
        step = (step + 1) & 15
      end
    end
  end

  # The pack the all-in-one build makes from the copy: every slot as the routine unpacks it.
  ALL_IN_ONE_PACK = VBlank::Original::Pack.holding({ palette: PALETTE.pack("v*"), walls: TILE_BYTES, heights: HEIGHTS.pack("C*") },
                                                   sha1: SHA1, build_version: "1").to_bytes

  # The pictures the all-in-one build of the port shows over GAME_PASSES passes.
  private def all_in_one_pictures(folder)
    device = Headless.new(frames: GAME_PASSES)
    Session.new(port(original(folder)).checked_program(err: nil, for_computer: true)).play(device)
    device.pictures.map(&:pixels)
  end

  # The shell of the port, as Ruby, built on a machine with no copy.
  private def shell(folder, version: "1")
    VBlank::Live::Shell.from(VBlank::Original::Shell.build(port(original(folder), version: version), err: nil))
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

  private def copy_at(folder)
    File.join(folder, "made_up.gba").tap { |path| File.binwrite(path, COPY) }
  end

  def test_the_first_start_unpacks_the_copy_keeps_the_pack_and_plays_the_game
    Dir.mktmpdir do |folder|
      played = play_shell(shell(folder), folder, picked: copy_at(folder))

      assert_equal 1, played.times_asked
      assert_empty played.refusals
      assert_equal GAME_PASSES, played.game_pictures.size
      assert_equal all_in_one_pictures(folder), played.game_pictures
    end
  end

  def test_the_pack_the_shell_keeps_is_the_all_in_one_builds_byte_for_byte
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))

      assert_equal ALL_IN_ONE_PACK, File.binread(File.join(folder, "kept", Shell::PACK_FILE))
    end
  end

  def test_the_next_start_plays_from_the_kept_pack_with_the_copy_gone
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))
      File.delete(File.join(folder, "made_up.gba"))
      played = play_shell(shell(folder), folder, picked: nil)

      assert_equal 0, played.times_asked
      assert_equal all_in_one_pictures(folder), played.game_pictures
    end
  end

  # A pack names the build of the game it was made for, so a new build asks for the copy again.
  def test_a_new_build_of_the_port_asks_for_the_copy_again
    Dir.mktmpdir do |folder|
      play_shell(shell(folder), folder, picked: copy_at(folder))
      played = play_shell(shell(folder, version: "2"), folder, picked: copy_at(folder))

      assert_equal 1, played.times_asked
      assert_match "not the data pack this build reads", played.refusals.first
      assert_equal VBlank::Original::Pack.read(File.join(folder, "kept", Shell::PACK_FILE)).build_version, "2"
    end
  end

  def test_a_copy_of_the_right_size_that_is_no_release_is_refused
    Dir.mktmpdir do |folder|
      wrong = File.join(folder, "wrong.gba")
      File.binwrite(wrong, COPY.reverse)
      played = play_shell(shell(folder), folder, picked: wrong, menu_frames: 40)

      assert_match "not a release of Made Up that this game knows", played.refusals.first
      assert_empty played.game_pictures
      refute File.exist?(File.join(folder, "kept", Shell::PACK_FILE))
    end
  end

  def test_a_file_no_release_is_the_size_of_is_refused_naming_the_size
    Dir.mktmpdir do |folder|
      short = File.join(folder, "short.gba")
      File.binwrite(short, COPY.byteslice(0, 100))
      played = play_shell(shell(folder), folder, picked: short, menu_frames: 40)

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
      assert File.exist?(File.join(folder, "kept", Shell::PACK_FILE))
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
  # and plays the game from the pack kept in its folder; a pack for another build it does not play.
  def test_a_shell_written_as_one_ruby_file_plays_from_the_kept_pack
    flunk "SDL3 is not installed: #{VBlank::Live::SDL::INSTALL_LINE}" unless VBlank::Live::SDL.available?

    Dir.mktmpdir do |folder|
      path = VBlank::IR::Backends::Ruby.new.build_script(port(original_nowhere(folder)), File.join(folder, "port-ruby.rb"),
                                                          console: :gba, err: StringIO.new, shell: true)
      kept = File.join(folder, "kept")
      FileUtils.mkdir_p(kept)
      File.binwrite(File.join(kept, Shell::PACK_FILE), ALL_IN_ONE_PACK)
      played, status = Open3.capture2e(ALONE, RbConfig.ruby, path, "--pictures", "3", "--pack-folder", kept,
                                       "--settings-file", File.join(folder, "settings.txt"), chdir: folder)

      assert status.success?, played
      assert_match(/3 frames in/, played)
      refute_includes File.binread(path), TILE_BYTES.byteslice(0, 16), "the file holds none of the copy's tiles"
    end
  end

  # The made-up original on a machine where no copy of it is set.
  private def original_nowhere(folder)
    VBlank::Original::Game.new(title: "Made Up", setting: "MADE_UP_ROM", env: {}, settings_file: File.join(folder, "made_up.yml"),
                               releases: { "Test" => { "sha1" => SHA1, "size" => COPY_SIZE } })
  end

  # A port whose code depends on what the copy holds cannot be a shell: the build stops, naming
  # the line that read the copy.
  def test_a_port_that_reads_the_copy_as_it_is_built_is_refused_as_a_shell
    Dir.mktmpdir do |folder|
      from = original(folder)
      game = VBlank.game("READS COPY", consoles: %i[gba]) do
        data_pack(from: from, version: "1") { |slots| slots.colors :palette, at: PALETTE_AT, count: 16 }
        from.copy
        game_loop { wait_vblank }
      end
      refused = assert_raises(VBlank::BuildError) { VBlank::Original::Shell.build(game, err: nil) }

      assert_match "cannot be built as a shell", refused.message
      assert_match "test_shell.rb:", refused.message
    end
  end
end
