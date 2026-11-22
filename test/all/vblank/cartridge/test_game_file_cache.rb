# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "open3"

# The library's game-code files are rewritten once and the text kept on disk. These tests count
# rewrites (a block the cache is handed) and never time a start.
class TestGameFileCache < Minitest::Test
  # Starts child processes, which hang inside a Ractor.
  runs_on_the_main_ractor!

  Cache = VBlank::Cartridge::GameFileCache

  def test_a_second_ask_for_the_same_file_does_not_rewrite
    in_temporary_folder do |dir|
      source = write_source(dir, "a = 1\n")
      rewrites = []
      2.times { Cache.new(File.join(dir, "cache")).rewritten(source) { rewrites << 1 && "text" } }
      assert_equal 1, rewrites.size
    end
  end

  def test_the_kept_text_is_what_the_block_returned
    in_temporary_folder do |dir|
      source = write_source(dir, "a = 1\n")
      cache = Cache.new(File.join(dir, "cache"))
      cache.rewritten(source) { "# frozen_string_literal: true\nb = 2\n" }
      assert_equal "# frozen_string_literal: true\nb = 2\n", cache.rewritten(source) { flunk "rewritten again" }
    end
  end

  def test_a_changed_file_is_rewritten
    in_temporary_folder do |dir|
      source = write_source(dir, "a = 1\n")
      cache = Cache.new(File.join(dir, "cache"))
      cache.rewritten(source) { "one" }
      File.write(source, "a = 2\n")
      assert_equal "two", cache.rewritten(source) { "two" }
    end
  end

  def test_a_folder_that_cannot_be_written_still_gives_the_text
    in_temporary_folder do |dir|
      source = write_source(dir, "a = 1\n")
      blocker = File.join(dir, "blocker")
      File.write(blocker, "a file, so no folder can be made below it")
      assert_equal "text", Cache.new(File.join(blocker, "cache")).rewritten(source) { "text" }
    end
  end

  def test_a_corrupt_entry_is_replaced
    in_temporary_folder do |dir|
      source = write_source(dir, "a = 1\n")
      cache = Cache.new(File.join(dir, "cache"))
      cache.rewritten(source) { "good" }
      entry = Dir[File.join(dir, "cache", "*.rb")].first
      damaged = File.binread(entry)
      File.binwrite(entry, damaged[0, damaged.size - 10])
      assert_equal "again", cache.rewritten(source) { "again" }
      assert_equal "again", cache.rewritten(source) { flunk "the entry was not replaced" }
    end
  end

  def test_an_empty_entry_is_replaced
    in_temporary_folder do |dir|
      source = write_source(dir, "a = 1\n")
      cache = Cache.new(File.join(dir, "cache"))
      cache.rewritten(source) { "good" }
      File.binwrite(Dir[File.join(dir, "cache", "*.rb")].first, "")
      assert_equal "again", cache.rewritten(source) { "again" }
    end
  end

  def test_it_is_off_when_asked
    assert_nil Cache.for_this_process(env: { "VBLANK_NO_CACHE" => "1", "HOME" => "/somewhere" })
  end

  def test_the_folder_comes_from_the_environment_in_order
    assert_equal "/x/game_files", Cache.for_this_process(env: { "VBLANK_CACHE_DIR" => "/x", "XDG_CACHE_HOME" => "/y" }).folder
    assert_equal "/y/vblank/game_files", Cache.for_this_process(env: { "XDG_CACHE_HOME" => "/y", "HOME" => "/h" }).folder
    assert_equal "/h/.cache/vblank/game_files", Cache.for_this_process(env: { "HOME" => "/h" }).folder
  end

  # A whole start in a child process: the first fills the folder, the second reads it and so writes
  # nothing (no entry is touched), and a folder that cannot be written changes nothing for the start.
  def test_a_second_start_reads_the_entries_the_first_wrote
    in_temporary_folder do |dir|
      assert start_library(dir)
      entries = Dir[File.join(dir, "game_files", "*.rb")]
      refute_empty entries
      before = entries.sort.to_h { |entry| [entry, File.binread(entry)] }
      stamped = entries.to_h { |entry| [entry, File.mtime(entry)] }
      assert start_library(dir)
      assert_equal before.keys, Dir[File.join(dir, "game_files", "*.rb")].sort
      assert_equal stamped, entries.to_h { |entry| [entry, File.mtime(entry)] }
    end
  end

  def test_a_start_with_a_folder_that_cannot_be_written
    in_temporary_folder do |dir|
      blocker = File.join(dir, "blocker")
      File.write(blocker, "a file")
      assert start_library(blocker)
    end
  end

  private

  def in_temporary_folder(&)
    Dir.mktmpdir("vblank-game-file-cache", &)
  end

  def write_source(dir, text)
    File.join(dir, "game_file.rb").tap { |path| File.write(path, text) }
  end

  def start_library(cache_dir)
    lib = File.expand_path("../../../../lib", __dir__)
    _out, err, status = Open3.capture3({ "VBLANK_CACHE_DIR" => cache_dir, "VBLANK_NO_CACHE" => nil },
                                       RbConfig.ruby, "-I", lib, "-e", 'require "vblank"; exit(VBlank::Builder.method_defined?(:sprite) ? 0 : 1)')
    warn err unless status.success?
    status.success?
  end
end
