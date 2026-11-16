# frozen_string_literal: true

require "test_helper"
require "digest/sha1"
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
      assert_equal Digest::SHA1.hexdigest(RIGHT), copy.sha1
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

  # A game made from a decompilation names more than its copy: the checkout and the assembler,
  # each found by the same rules and refused in the same kind of error.
  private def decompiling(folder, env: {})
    game(folder, env: env, paths: {
           checkout: { setting: "SPACE_PINBALL_DISASSEMBLY", key: "disassembly", folder: true, what: "a checkout of the disassembly" },
           assembler: { setting: "SPACE_PINBALL_ASSEMBLER", key: "assembler", what: "the assembler's program" }
         })
  end

  def test_each_path_a_game_names_is_found_by_its_setting_or_the_settings_file
    Dir.mktmpdir do |folder|
      Dir.mkdir(File.join(folder, "disasm"))
      assembler = write(folder, "rgbasm", "#!")
      write(folder, "space_pinball.yml", "disassembly: disasm\nassembler: /nowhere\n")

      paths = decompiling(folder, env: { "SPACE_PINBALL_ASSEMBLER" => assembler })

      assert_equal File.join(folder, "disasm"), paths.path(:checkout)
      assert_equal assembler, paths.path(:assembler)
    end
  end

  def test_a_path_not_set_or_not_there_is_refused_saying_what_to_set
    Dir.mktmpdir do |folder|
      write(folder, "space_pinball.yml", "disassembly: missing\n")

      not_set = assert_raises(VBlank::Original::NotSet) { decompiling(folder).path(:assembler) }
      wrong = assert_raises(VBlank::Original::WrongPath) { decompiling(folder).path(:checkout) }

      assert_match "SPACE_PINBALL_ASSEMBLER", not_set.message
      assert_match "the assembler's program", not_set.message
      assert_match "folder", wrong.message
      assert_raises(ArgumentError) { decompiling(folder).path(:linker) }
    end
  end

  def test_a_settings_file_that_is_not_yaml_is_a_wrong_path_for_a_path
    Dir.mktmpdir do |folder|
      write(folder, "space_pinball.yml", "disassembly: [unclosed\n")

      assert_raises(VBlank::Original::WrongPath) { decompiling(folder).path(:checkout) }
    end
  end

  def test_a_file_a_probe_accepts_is_hashed
    Dir.mktmpdir do |folder|
      path = write(folder, "copy.bin", RIGHT)

      copy = game(folder, env: named(path), releases: nil, probe: ->(_) { "full" }).copy

      assert_equal Digest::SHA1.hexdigest(RIGHT), copy.sha1
    end
  end

  def test_a_file_where_a_folder_is_named_is_refused
    Dir.mktmpdir do |folder|
      file = write(folder, "not_a_folder", "")

      assert_raises(VBlank::Original::WrongPath) { decompiling(folder, env: { "SPACE_PINBALL_DISASSEMBLY" => file }).path(:checkout) }
    end
  end

  def test_a_game_names_releases_or_a_probe
    assert_raises(ArgumentError) { game(Dir.tmpdir, releases: nil) }
  end

  # A GAME THAT ACCEPTS BY SHA-1 AND NAMES BY ITS HEADER: two releases of made-up bytes, each
  # starting with a region of its own, and a probe that reads the region as a game reads its
  # cartridge's header. The digest decides what is accepted; the probe only names what is refused.
  US_DUMP = "US:the release this game reads"
  EU_DUMP = "EU:the european release, longer"

  private def headed_releases(eu_size: EU_DUMP.bytesize)
    { "US" => { "sha1" => Digest::SHA1.hexdigest(US_DUMP), "size" => US_DUMP.bytesize },
      "EU" => { "sha1" => Digest::SHA1.hexdigest(EU_DUMP), "size" => eu_size } }
  end

  private def header_probe(asked = [])
    lambda do |path|
      asked << path
      { "US:" => "US", "EU:" => "EU" }[File.binread(path, 3)]
    end
  end

  def test_a_copy_accepted_by_sha1_is_not_probed
    Dir.mktmpdir do |folder|
      asked = []
      path = write(folder, "us.gba", US_DUMP)

      copy = game(folder, env: named(path), releases: headed_releases, probe: header_probe(asked)).copy

      assert_equal "US", copy.release
      assert_empty asked
    end
  end

  def test_a_damaged_dump_of_another_release_is_refused_naming_that_release
    Dir.mktmpdir do |folder|
      path = write(folder, "eu.gba", EU_DUMP.tr("l", "L"))

      error = assert_raises(VBlank::Original::WrongCopy) do
        game(folder, env: named(path), releases: headed_releases, probe: header_probe).copy
      end
      assert_match "the EU release", error.message
      assert_match "damaged", error.message
      assert_match Digest::SHA1.hexdigest(EU_DUMP), error.message
    end
  end

  def test_a_short_dump_named_by_the_probe_is_refused_with_its_length_and_its_release
    Dir.mktmpdir do |folder|
      path = write(folder, "eu.gba", EU_DUMP[0, 10])

      error = assert_raises(VBlank::Original::WrongCopy) do
        game(folder, env: named(path), releases: headed_releases, probe: header_probe).copy
      end
      assert_match "the EU release", error.message
      assert_match "10 bytes", error.message
      assert_match "#{EU_DUMP.bytesize} bytes", error.message
    end
  end

  def test_a_short_dump_is_told_its_length_when_another_release_has_no_size
    Dir.mktmpdir do |folder|
      path = write(folder, "us.gba", US_DUMP[0, 10])
      unsized = headed_releases(eu_size: nil)

      error = assert_raises(VBlank::Original::WrongCopy) { game(folder, env: named(path), releases: unsized).copy }
      assert_match "10 bytes", error.message
      assert_match "#{US_DUMP.bytesize} bytes", error.message

      probed = assert_raises(VBlank::Original::WrongCopy) do
        game(folder, env: named(path), releases: unsized, probe: header_probe).copy
      end
      assert_match "the US release", probed.message
      assert_match "10 bytes", probed.message
    end
  end

  def test_a_dump_of_a_release_with_no_size_is_named_damaged_whatever_its_length
    Dir.mktmpdir do |folder|
      path = write(folder, "eu.gba", EU_DUMP[0, 10])

      error = assert_raises(VBlank::Original::WrongCopy) do
        game(folder, env: named(path), releases: headed_releases(eu_size: nil), probe: header_probe).copy
      end
      assert_match "the EU release", error.message
      assert_match "damaged", error.message
    end
  end
end
