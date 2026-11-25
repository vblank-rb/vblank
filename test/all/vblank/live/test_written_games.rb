# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"
require "vblank/live"

# GAMES vblank run wrote out, kept while current (Live::WrittenGames), and the record of what each
# build read that says whether they are (Live::BuildInputs). test_cli.rb plays the launches; this
# holds what a launch cannot show: a change to VBlank itself, each kind of read, and that a kept
# game is its owner's alone.
class TestWrittenGames < Minitest::Test
  # Recording wraps the methods the whole process reads files and the environment with.
  runs_on_the_main_ractor!

  WrittenGames = VBlank::Live::WrittenGames
  BuildInputs = VBlank::Live::BuildInputs
  LIBRARY_ONE = WrittenGames::LibraryKey.new(digest: "one", gems: ["fiddle 1.0"])
  LIBRARY_TWO = WrittenGames::LibraryKey.new(digest: "one", gems: ["fiddle 1.1"]) # a gem of another version

  # A slot in +root+ with a game kept, built from +inputs+ by the library +library+.
  private def kept_slot(root, inputs: BuildInputs.new, library: LIBRARY_ONE)
    slot = WrittenGames.new(root).slot(game_file: File.join(root, "demo.rb"), console: :gba, settings: { shade: "2" })
    slot.prepare
    File.write(slot.writing_path, "# the game\n")
    slot.keep(inputs, console: :gba, settings: { shade: "2" }, library: library)
    slot
  end

  def test_a_kept_game_is_current_only_for_its_console_settings_and_library
    Dir.mktmpdir do |root|
      slot = kept_slot(root)

      assert slot.current?(console: :gba, settings: { shade: "2" }, library: LIBRARY_ONE)
      refute slot.current?(console: :gbc, settings: { shade: "2" }, library: LIBRARY_ONE)
      refute slot.current?(console: :gba, settings: {}, library: LIBRARY_ONE)
      refute slot.current?(console: :gba, settings: { shade: "2" }, library: LIBRARY_TWO)
    end
  end

  # The library's digest is every file under it, by place and contents.
  def test_the_library_digest_changes_with_any_file_of_the_library
    Dir.mktmpdir do |lib|
      FileUtils.mkdir_p(File.join(lib, "vblank", "data"))
      File.write(File.join(lib, "vblank.rb"), "# one\n")
      File.write(File.join(lib, "vblank", "data", "table.txt"), "1 2 3\n")
      before = WrittenGames.library_digest(lib)
      File.write(File.join(lib, "vblank", "data", "table.txt"), "1 2 4\n")

      refute_equal before, WrittenGames.library_digest(lib)
    end
  end

  # A build that stopped part way, its record taken away as it began, leaves nothing current.
  def test_a_slot_made_ready_for_a_build_is_no_longer_current
    Dir.mktmpdir do |root|
      slot = kept_slot(root)
      slot.prepare

      refute slot.current?(console: :gba, settings: { shade: "2" }, library: LIBRARY_ONE)
    end
  end

  # A written game can hold an original's data, so it is its owner's alone.
  def test_a_kept_game_and_its_folder_are_the_owners_alone
    Dir.mktmpdir do |root|
      slot = kept_slot(File.join(root, "written games"))

      assert_equal 0o700, File.stat(slot.folder).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(slot.folder)).mode & 0o777
      assert_equal 0o600, File.stat(slot.script_path).mode & 0o777
      assert_equal 0o600, File.stat(slot.record_path).mode & 0o777
    end
  end

  def test_the_root_is_the_one_named_else_the_computers_place_for_caches
    assert_equal "/mine", WrittenGames.root(env: { "VBLANK_WRITTEN_GAMES" => "/mine" }, home: "/home/me", mac: false)
    assert_equal "/home/me/Library/Caches/vblank/written-games", WrittenGames.root(env: {}, home: "/home/me", mac: true)
    assert_equal "/xdg/vblank/written-games", WrittenGames.root(env: { "XDG_CACHE_HOME" => "/xdg" }, home: "/home/me", mac: false)
    assert_equal "/home/me/.cache/vblank/written-games", WrittenGames.root(env: {}, home: "/home/me", mac: false)
  end

  # Each kind of read a build makes is recorded, and a change to any of them is seen.
  def test_each_kind_of_read_is_recorded_and_its_change_seen
    Dir.mktmpdir do |dir|
      level = File.join(dir, "level.txt")
      opened = File.join(dir, "opened.txt")
      File.write(level, "1")
      File.write(opened, "a")
      File.write(File.join(dir, "room1.map"), "")
      changes = {
        "a file read" => -> { File.write(level, "2") },
        "a file opened" => -> { File.write(opened, "b") },
        "a file a glob finds" => -> { File.write(File.join(dir, "room2.map"), "") },
        "a file asked about" => -> { File.write(File.join(dir, "optional.txt"), "") },
        "a setting" => -> { ENV["VBLANK_TEST_WRITTEN_GAMES_LEVEL"] = "hard" }
      }
      changes.each do |what, change|
        inputs = BuildInputs.recording do
          File.read(level)
          File.open(opened, &:read)
          Dir.glob("*.map", base: dir)
          File.exist?(File.join(dir, "optional.txt"))
          ENV.fetch("VBLANK_TEST_WRITTEN_GAMES_LEVEL", "easy")
        end
        replayed = BuildInputs.from_plain(JSON.parse(JSON.generate(inputs.to_plain)))

        assert replayed.current?, "nothing has changed yet, before #{what}"
        change.call
        refute replayed.current?, what
      end
    ensure
      ENV.delete("VBLANK_TEST_WRITTEN_GAMES_LEVEL")
    end
  end

  # A kept game that is not as its build left it (edited, or cut short by another build at the same
  # moment) is not current.
  def test_a_kept_game_changed_since_its_build_is_not_current
    Dir.mktmpdir do |root|
      slot = kept_slot(root)
      File.write(slot.script_path, "# something else\n")

      refute slot.current?(console: :gba, settings: { shade: "2" }, library: LIBRARY_ONE)
    end
  end

  # Two builds at once each write a file of their own, so neither takes the other's half-written one.
  def test_each_build_writes_the_game_under_a_name_of_its_own
    Dir.mktmpdir do |root|
      slot = WrittenGames.new(root).slot(game_file: File.join(root, "demo.rb"), console: :gba, settings: {})

      assert_includes File.basename(slot.writing_path), Process.pid.to_s
    end
  end

  # The working folder is part of what a game is kept for: a build reads a path relative to it.
  def test_a_game_launched_from_another_folder_is_kept_apart
    Dir.mktmpdir do |root|
      games = WrittenGames.new(root)
      here = games.slot(game_file: "/games/demo.rb", console: :gba, settings: {}, working_folder: "/one")
      there = games.slot(game_file: "/games/demo.rb", console: :gba, settings: {}, working_folder: "/two")

      refute_equal here.folder, there.folder
    end
  end

  # A folder made already keeps its own permissions: the root is made the owner's alone only when
  # this makes it.
  def test_a_root_made_already_keeps_its_permissions
    Dir.mktmpdir do |root|
      File.chmod(0o755, root)
      kept_slot(root)

      assert_equal 0o755, File.stat(root).mode & 0o777
    end
  end

  # A kept game anyone else can write to is never played: it is built again.
  def test_a_kept_game_others_can_write_to_is_not_current
    Dir.mktmpdir do |root|
      slot = kept_slot(root)
      File.chmod(0o620, slot.script_path)

      refute slot.current?(console: :gba, settings: { shade: "2" }, library: LIBRARY_ONE)
      File.chmod(0o600, slot.script_path)
      File.chmod(0o770, slot.folder)

      refute slot.current?(console: :gba, settings: { shade: "2" }, library: LIBRARY_ONE)
    end
  end

  # The library's part of the key names every gem loaded and its version.
  def test_the_library_key_names_the_gems_loaded
    key = WrittenGames.library_key

    Gem.loaded_specs.each_value { |spec| assert_includes key.gems, "#{spec.name} #{spec.version}" }
  end

  # Pictures are read by another program (ImageMagick), which no Ruby read sees, so VBlank says
  # it hands the file over (BuildInputs.note_read). A picture named by its full path, and the
  # picture behind an Aseprite export, are recorded, and an edit to either is seen.
  def test_a_picture_another_program_reads_is_recorded
    Dir.mktmpdir do |dir|
      picture = File.join(dir, "ship.png")
      FileUtils.cp(VBlank.root.join("test/fixtures/import_2x2.png"), picture)
      FileUtils.cp(VBlank.root.join("test/fixtures/aseprite/hero.json"), dir)
      FileUtils.cp(VBlank.root.join("test/fixtures/aseprite/hero.png"), dir)
      exported = File.join(dir, "hero.json")
      inputs = BuildInputs.recording do
        VBlank.build("PICTURES", console: :gba, out: StringIO.new, err: StringIO.new) do
          screen :tiled
          image :ship, from: picture, width: 2, height: 2
          sprite :hero, at: [40, 40], from_aseprite: exported
          game_loop { wait_vblank }
        end
      end

      assert inputs.current?
      File.binwrite(picture, File.binread(picture) + "\0")
      refute inputs.current?, "the picture named by its full path"
      FileUtils.cp(VBlank.root.join("test/fixtures/import_2x2.png"), picture)
      assert inputs.current?
      File.binwrite(File.join(dir, "hero.png"), File.binread(File.join(dir, "hero.png")) + "\0")
      refute inputs.current?, "the picture behind the Aseprite export"
    end
  end

  # Reads made other ways than reading a file by its name are recorded too: a file loaded as Ruby,
  # a folder opened and listed, the whole environment, and a glob given its flags by name.
  def test_loads_opened_folders_the_whole_environment_and_glob_flags_are_recorded
    Dir.mktmpdir do |dir|
      loaded = File.join(dir, "loaded.rb")
      File.write(loaded, "1\n")
      FileUtils.mkdir_p(File.join(dir, "rooms"))
      changes = {
        "a file loaded" => -> { File.write(loaded, "2\n") },
        "a folder opened" => -> { File.write(File.join(dir, "rooms", "room2"), "") },
        "the whole environment" => -> { ENV["VBLANK_TEST_WRITTEN_GAMES_WHOLE"] = "now" },
        "a hidden file a glob finds with its flags" => -> { File.write(File.join(dir, ".secret.map"), "") }
      }
      changes.each do |what, change|
        inputs = BuildInputs.recording do
          load loaded
          Dir.new(File.join(dir, "rooms")).each { |name| name }
          ENV.to_h
          Dir.glob("*.map", flags: File::FNM_DOTMATCH, base: dir)
        end

        assert inputs.current?, "nothing has changed yet, before #{what}"
        change.call
        refute inputs.current?, what
      end
    ensure
      ENV.delete("VBLANK_TEST_WRITTEN_GAMES_WHOLE")
    end
  end

  # A file written as the build runs is not something it read.
  def test_a_file_written_is_not_recorded
    Dir.mktmpdir do |dir|
      written = File.join(dir, "out.txt")
      inputs = BuildInputs.recording { File.open(written, "w") { |file| file.write("x") } }

      refute inputs.paths.key?(written)
    end
  end
end
