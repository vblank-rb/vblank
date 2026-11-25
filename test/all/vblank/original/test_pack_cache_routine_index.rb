# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "made_up_original"

# A build whose pack is kept builds no unpacking routine. Building a port's routine takes a big
# port many seconds, and a build drawn from a kept pack used to build it all the same, only to work
# out the pack's key. The pack cache now keeps, beside each pack, what the routine was built from:
# the files read while it was built, each with its digest. A later build whose files are unchanged
# reads the pack without building the routine. The answer key is the same game built with no cache.
class TestPackCacheRoutineIndex < Minitest::Test
  include MadeUpOriginal

  # How many times the routine's block was built. Not a plain number: a number the block holds is
  # part of what the routine is declared from, and would change it.
  Counter = Struct.new(:count)

  # The made-up port, its walls unpacked only where the file +choice+ holds "unpack", so the
  # routine is built from a data file it reads as it is built. +built+ counts the builds.
  private def game_choosing_walls(folder, cache, choice, built)
    game_program(lambda do |builder|
      pack = builder.data_pack(from: original(folder), version: "1", cache: cache) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          built.count += 1
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls] if File.read(choice).strip == "unpack"
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:heights])]
    end)
  end

  private def picture(program) = game_player.run(program, frames: 3).screen.to_a

  # The picture of the game built with no cache, the file +choice+ holding +chosen+.
  private def answer(folder, chosen)
    choice = File.join(folder, "answer_choice.txt")
    File.write(choice, chosen)
    picture(game_choosing_walls(folder, nil, choice, Counter.new(0)))
  end

  def test_a_second_build_with_the_pack_kept_builds_no_routine
    Dir.mktmpdir do |folder|
      choice = File.join(folder, "choice.txt")
      File.write(choice, "unpack")
      built = Counter.new(0)
      first = picture(game_choosing_walls(folder, File.join(folder, "packs"), choice, built))
      second = picture(game_choosing_walls(folder, File.join(folder, "packs"), choice, built))

      assert_equal 1, built.count
      assert_equal answer(folder, "unpack"), first
      assert_equal first, second
    end
  end

  # A new process has no routine built before: the cache on disk alone says the pack is kept.
  def test_a_build_with_no_routine_built_before_reads_the_kept_pack
    Dir.mktmpdir do |folder|
      choice = File.join(folder, "choice.txt")
      File.write(choice, "unpack")
      built = Counter.new(0)
      first = picture(game_choosing_walls(folder, File.join(folder, "packs"), choice, built))
      VBlank::Original::RoutineBuild.forget_built
      second = picture(game_choosing_walls(folder, File.join(folder, "packs"), choice, built))

      assert_equal 1, built.count
      assert_equal first, second
    end
  end

  def test_a_changed_file_the_routine_reads_builds_it_again
    Dir.mktmpdir do |folder|
      choice = File.join(folder, "choice.txt")
      File.write(choice, "leave")
      built = Counter.new(0)
      before = picture(game_choosing_walls(folder, File.join(folder, "packs"), choice, built))
      File.write(choice, "unpack")
      after = picture(game_choosing_walls(folder, File.join(folder, "packs"), choice, built))

      assert_equal 2, built.count
      assert_equal answer(folder, "leave"), before
      assert_equal answer(folder, "unpack"), after
      refute_equal before, after
    end
  end

  # The routine is built again where the file changed, and the program it builds is the one kept
  # before, so the pack kept for it is read and the routine is not played again.
  def test_a_file_changed_back_reads_the_pack_kept_for_it
    Dir.mktmpdir do |folder|
      choice = File.join(folder, "choice.txt")
      cache = File.join(folder, "packs")
      built = Counter.new(0)
      File.write(choice, "unpack")
      first = picture(game_choosing_walls(folder, cache, choice, built))
      File.write(choice, "leave")
      picture(game_choosing_walls(folder, cache, choice, built))
      File.write(choice, "unpack")
      again = picture(game_choosing_walls(folder, cache, choice, built))

      assert_equal 3, built.count
      assert_equal first, again
      assert_equal 2, Dir.glob(File.join(cache, "*#{VBlank::Original::PackCache::ENTRY_EXTENSION}")).size
    end
  end

  # What a port read from a file of its own before its pack is declared, as a game file reads its
  # levels as it loads. Not plain data, so only the file it was read from tells two apart.
  Levels = Struct.new(:unpack_walls)

  private def read_levels(path) = Levels.new(File.read(path).strip == "unpack")

  # The made-up port, its walls unpacked where +levels+ (read before) says so.
  private def game_reading_levels(folder, cache, levels, built)
    game_program(lambda do |builder|
      pack = builder.data_pack(from: original(folder), version: "1", cache: cache) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          built.count += 1
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls] if levels.unpack_walls
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:heights])]
    end)
  end

  # A folder of the repository's that git ignores, since a file read outside the routine's build is
  # passed over in the machine's folder for temporary files, which holds a build's own scratch.
  private def in_ignored_folder(&)
    Dir.mktmpdir("pack-cache-index-", VBlank.root.join("build").tap(&:mkpath), &)
  end

  def test_a_changed_file_read_before_the_pack_is_declared_builds_the_routine_again
    in_ignored_folder do |folder|
      path = File.join(folder, "levels.txt")
      cache = File.join(folder, "packs")
      built = Counter.new(0)
      File.write(path, "leave")
      before = picture(game_reading_levels(folder, cache, read_levels(path), built))
      File.write(path, "unpack")
      after = picture(game_reading_levels(folder, cache, read_levels(path), built))

      assert_equal 2, built.count
      assert_equal picture(game_reading_levels(folder, nil, read_levels(path), Counter.new(0))), after
      refute_equal before, after
    end
  end

  # With no cache the routine is built once all the same, and later builds of the same game in
  # this process share it.
  def test_builds_with_no_cache_share_the_routine_built_first
    Dir.mktmpdir do |folder|
      choice = File.join(folder, "choice.txt")
      File.write(choice, "unpack")
      built = Counter.new(0)
      first = picture(game_choosing_walls(folder, nil, choice, built))
      second = picture(game_choosing_walls(folder, nil, choice, built))

      assert_equal 1, built.count
      assert_equal first, second
    end
  end

  # Reads are watched from the moment the library loads, so every other open in the process passes
  # through the watch: a file opened by its flags, as Tempfile opens one, opens as it would without it.
  def test_a_file_opened_by_its_flags_opens_with_reads_watched
    Tempfile.create("watched") do |file|
      file.write("kept")
      file.flush

      assert_equal "kept", File.read(file.path)
    end
    assert VBlank::Original::FilesRead.write_only?(File::WRONLY | File::CREAT)
    refute VBlank::Original::FilesRead.write_only?(File::RDWR | File::CREAT)
    refute VBlank::Original::FilesRead.write_only?(File::RDONLY)
  end
end
