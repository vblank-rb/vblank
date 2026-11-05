# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# A port must never commit the original's data, and once a blob is in history it is there for good.
# Original::DataGuard is the check a game's pre-commit hook runs over the staged files: the
# original's own kinds of file for the consoles the game names, the folders the game names, a file a
# tool wrote from the original, and anything big.
class TestDataGuard < Minitest::Test
  # One test starts git, a child process, to read a repository's index.
  runs_on_the_main_ractor!

  MARK = "# rocket: written from the original"

  private def staged(path, size: 10, first_line: "# frozen_string_literal: true")
    VBlank::Original::StagedFile.new(path: path, size: size, first_line: first_line)
  end

  private def guard(**how) = VBlank::Original::DataGuard.new(consoles: %i[gbc], **how)

  private def git(folder, *arguments) = system("git", "-C", folder, *arguments, exception: true, out: File::NULL, err: File::NULL)

  def test_ordinary_source_passes
    assert_empty guard.refusals([staged("lib/rocket/ship.rb"), staged("data/facts/ship.yml")])
  end

  def test_a_cartridge_and_its_save_for_a_console_named_are_refused
    refusals = guard.refusals([staged("Rocket.gbc"), staged("games/rocket/Rocket.GB"), staged("rocket.sav")])

    assert_equal 1, refusals.size
    %w[Rocket.gbc Rocket.GB rocket.sav].each { |path| assert_match path, refusals.first }
  end

  def test_a_console_not_named_keeps_its_kinds_of_file
    assert_empty guard.refusals([staged("test/fixtures/tiny.sfc")])
    refute_empty guard(consoles: %i[gbc snes]).refusals([staged("test/fixtures/tiny.sfc")])
  end

  def test_the_folders_and_kinds_the_game_names_are_refused
    rocket = guard(folders: %w[dumps/ /cache/ *.levels/ data/raw/], suffixes: %w[chr])

    refused = %w[dumps/ship.png games/rocket/DUMPS/notes.txt cache/a.txt moon.levels/map.txt data/raw/x.txt art/ship.chr]
    refusals = rocket.refusals(refused.map { staged(it) })

    refused.each { |path| assert_match path, refusals.join }
    assert_empty rocket.refusals(%w[lib/dumpster.rb lib/cache/store.rb levels/map.txt data/rawer/x.txt].map { staged(it) })
  end

  def test_a_file_a_tool_wrote_from_the_original_is_refused_by_its_first_line
    rocket = guard(generated_mark: MARK)

    refusals = rocket.refusals([staged("lib/rocket/table.rb", first_line: "#{MARK}, by a tool")])

    assert_match "lib/rocket/table.rb", refusals.join
    assert_empty rocket.refusals([staged("lib/rocket/tool.rb", first_line: "# writes '#{MARK}'")])
  end

  def test_a_big_file_is_refused
    refusals = guard.refusals([staged("art/big.png", size: 600_000)])

    assert_match "art/big.png", refusals.join
    assert_empty guard(most_bytes: 1_000_000).refusals([staged("art/big.png", size: 600_000)])
  end

  def test_the_staged_files_of_a_repository_are_read_from_its_index
    Dir.mktmpdir do |folder|
      git(folder, "init", "--quiet")
      File.write(File.join(folder, "game.gbc"), "#{'x' * 20}\nmore")
      File.binwrite(File.join(folder, "picture.png"), "\x89PNG\r\n#{"\xff" * 2000}".b)
      git(folder, "add", "game.gbc", "picture.png")

      files = VBlank::Original::DataGuard.staged_files(folder)

      assert_equal [staged("game.gbc", size: 25, first_line: "x" * 20), staged("picture.png", size: 2006, first_line: "�PNG")],
                   files
    end
  end

  def test_a_file_renamed_into_a_cartridge_is_read_as_staged
    Dir.mktmpdir do |folder|
      git(folder, "init", "--quiet")
      File.write(File.join(folder, "notes.txt"), "notes\n" * 50)
      git(folder, "add", "notes.txt")
      git(folder, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "--no-verify", "-m", "notes")
      git(folder, "mv", "notes.txt", "game.gbc")

      assert_includes VBlank::Original::DataGuard.staged_files(folder).map(&:path), "game.gbc"
    end
  end
end
