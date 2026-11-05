# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# A game made from an original names its copy once (Original::Game) and asks for it: found by a
# setting or the game's settings file, accepted by its digest or by a probe of its own, and refused
# in one error that says what to set. The copies here are made-up bytes.
class TestOriginalGame < Minitest::Test
  RIGHT = "the release this game reads"
  OTHER = "another release of the game, longer"
  DEMO = "a demo"

  private def releases
    { "US" => { "sha1" => Digest::SHA1.hexdigest(RIGHT), "size" => RIGHT.bytesize },
      "JP" => { "sha1" => Digest::SHA1.hexdigest(OTHER), "size" => OTHER.bytesize, "supported" => false },
      "DEMO" => { "md5" => Digest::MD5.hexdigest(DEMO), "size" => DEMO.bytesize } }
  end

  private def game(folder, env: {}, **how)
    VBlank::Original::Game.new(title: "Space Pinball", setting: "SPACE_PINBALL_ROM", env: env,
                               settings_file: File.join(folder, "space_pinball.yml"), **{ releases: releases }.merge(how))
  end

  private def write(folder, name, bytes)
    File.join(folder, name).tap { |path| File.binwrite(path, bytes) }
  end

  private def named(path) = { "SPACE_PINBALL_ROM" => path }

  def test_the_setting_names_the_copy_before_the_settings_file
    Dir.mktmpdir do |folder|
      path = write(folder, "named.gb", RIGHT)
      write(folder, "space_pinball.yml", "rom: elsewhere.gb\n")

      copy = game(folder, env: named(path)).copy

      assert_equal path, copy.path
      assert_equal "US", copy.release
    end
  end

  def test_a_path_in_the_settings_file_is_read_beside_it
    Dir.mktmpdir do |folder|
      Dir.mkdir(File.join(folder, "roms"))
      write(folder, "roms/space_pinball.gb", RIGHT)
      write(folder, "space_pinball.yml", "rom: roms/space_pinball.gb\n")

      assert_equal File.join(folder, "roms/space_pinball.gb"), game(folder).copy.path
    end
  end

  def test_nothing_set_is_no_copy_and_says_what_to_set
    Dir.mktmpdir do |folder|
      write(folder, "space_pinball.example.yml", "rom: /path/to/your/copy\n")

      assert_nil game(folder).copy_if_set
      error = assert_raises(VBlank::Original::NotSet) { game(folder, not_set_help: "It must be a .gb file.").copy }
      assert_match "SPACE_PINBALL_ROM", error.message
      assert_match "space_pinball.example.yml", error.message
      assert_match "It must be a .gb file.", error.message
    end
  end

  def test_a_named_copy_that_is_not_there_is_refused_even_when_asked_if_set
    Dir.mktmpdir do |folder|
      error = assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(File.join(folder, "gone.gb"))).copy_if_set }

      assert_match "gone.gb", error.message
    end
  end

  def test_a_settings_file_that_is_not_yaml_is_refused
    Dir.mktmpdir do |folder|
      write(folder, "space_pinball.yml", "rom: [unclosed\n")

      assert_match "space_pinball.yml", assert_raises(VBlank::Original::WrongCopy) { game(folder).copy }.message
    end
  end

  def test_a_folder_is_refused_where_a_file_is_read
    Dir.mktmpdir do |folder|
      assert_match "folder", assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(folder)).copy }.message
    end
  end

  def test_a_copy_no_release_is_the_length_of_is_refused_unread
    Dir.mktmpdir do |folder|
      path = write(folder, "short.gb", "short")

      error = assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(path)).copy }
      assert_match RIGHT.bytesize.to_s, error.message
    end
  end

  def test_bytes_no_release_has_are_refused_naming_the_release_wanted
    Dir.mktmpdir do |folder|
      path = write(folder, "patched.gb", RIGHT.tr("a", "b"))

      error = assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(path)).copy }
      assert_match Digest::SHA1.hexdigest(RIGHT.tr("a", "b")), error.message
      assert_match "US", error.message
    end
  end

  def test_a_known_release_the_game_does_not_read_is_named_whatever_its_length
    Dir.mktmpdir do |folder|
      japan = write(folder, "japan.gb", OTHER)
      demo = write(folder, "demo.gb", DEMO)

      assert_match "JP release", assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(japan)).copy }.message
      assert_match "DEMO release", assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(demo)).copy }.message
    end
  end

  def test_releases_listed_by_entry_are_read_the_same
    Dir.mktmpdir do |folder|
      path = write(folder, "japan.gb", OTHER)
      listed = [{ "name" => "US", "sha1" => Digest::SHA1.hexdigest(RIGHT) }, { "name" => "JP", "sha1" => Digest::SHA1.hexdigest(OTHER) }]

      assert_equal "JP", game(folder, env: named(path), releases: listed).copy.release
    end
  end

  def test_a_probe_accepts_a_folder_and_names_its_release
    Dir.mktmpdir do |folder|
      Dir.mkdir(File.join(folder, "data"))
      write(folder, "data/LEVELS.DAT", "levels")
      probe = ->(path) { File.exist?(File.join(path, "LEVELS.DAT")) ? "full" : nil }

      copy = game(folder, env: named(File.join(folder, "data")), releases: nil, probe: probe).copy

      assert_equal "full", copy.release
    end
  end

  def test_a_probe_that_names_no_release_refuses_the_copy
    Dir.mktmpdir do |folder|
      Dir.mkdir(File.join(folder, "empty"))

      assert_raises(VBlank::Original::WrongCopy) do
        game(folder, env: named(File.join(folder, "empty")), releases: nil, probe: ->(_) {}).copy
      end
    end
  end

  def test_a_game_names_releases_or_a_probe
    assert_raises(ArgumentError) { game(Dir.tmpdir, releases: nil) }
  end
end
