# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "made_up_original"

# A PORT'S UNPACKING IS RUN ONCE FOR A COPY AND A ROUTINE. Built all-in-one, a game's unpacking
# routine runs on the interpreter as the game is built, which for a big port takes most of a
# minute; `data_pack(cache:)` keeps what it wrote, so the next build with the same copy and the same
# routine reads that back. The answer key is the same game built with no cache.
class TestPackCache < Minitest::Test
  include MadeUpOriginal

  # The made-up port's unpacked pack, kept in +cache+; +swapped+ writes the routine's two lines the
  # other way round, which fills the same slots with a routine that is not the same.
  private def cached_game(folder, cache, swapped: false)
    game_program(lambda do |builder|
      pack = builder.data_pack(from: original(folder), version: "1", cache: cache) do |slots|
        slots.colors :palette, at: PALETTE_AT, count: 16
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          if swapped
            copy.unpack_rle at: RLE_AT, into: into[:heights]
            copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
          else
            copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
            copy.unpack_rle at: RLE_AT, into: into[:heights]
          end
        end
      end
      [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:heights])]
    end)
  end

  private def picture(program) = game_player.run(program, frames: 3).screen.to_a

  private def kept_entries(cache) = Dir.glob(File.join(cache, "**", "*.pack"))

  # What was kept, its walls made blank, so a build that reads it draws something else.
  private def blank_the_kept_walls(cache)
    kept_entries(cache).each do |path|
      slots = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad -- the test's own file
      File.binwrite(path, Marshal.dump(slots.merge(walls: "\0".b * slots.fetch(:walls).bytesize)))
    end
  end

  def test_a_second_build_with_the_same_copy_and_routine_reads_what_the_first_kept
    Dir.mktmpdir do |folder|
      cache = File.join(folder, "packs")
      first = picture(cached_game(folder, cache))

      assert_equal 1, kept_entries(cache).size
      assert_equal first, picture(cached_game(folder, cache)), "a pack read back plays as the one it was made from"

      blank_the_kept_walls(cache)

      refute_equal first, picture(cached_game(folder, cache)), "the second build reads the kept pack, not the routine"
    end
  end

  def test_a_changed_routine_makes_the_pack_again
    Dir.mktmpdir do |folder|
      cache = File.join(folder, "packs")
      first = picture(cached_game(folder, cache))
      blank_the_kept_walls(cache)

      assert_equal first, picture(cached_game(folder, cache, swapped: true))
      assert_equal 2, kept_entries(cache).size
    end
  end

  # The key is made from the copy's bytes themselves, so a different copy makes its pack again even
  # where it says it has the SHA-1 of the copy kept before.
  def test_a_different_copy_makes_the_pack_again_whatever_its_sha1_says
    Dir.mktmpdir do |folder|
      cache = File.join(folder, "packs")
      program = halting_program
      kept = VBlank::Original::PackCache.new(cache)
      first = kept.slot_bytes(UnpackingOfCopy.new(program: program, copy_bytes: "one copy")) { { walls: "first" } }
      second = kept.slot_bytes(UnpackingOfCopy.new(program: program, copy_bytes: "another copy")) { { walls: "second" } }

      assert_equal [{ walls: "first" }, { walls: "second" }], [first, second]
      assert_equal 2, kept_entries(cache).size
    end
  end

  def test_an_entry_that_cannot_be_read_is_made_again
    Dir.mktmpdir do |folder|
      cache = File.join(folder, "packs")
      first = picture(cached_game(folder, cache))
      kept_entries(cache).each { |path| File.binwrite(path, "not a pack") }

      assert_equal first, picture(cached_game(folder, cache))
    end
  end

  def test_an_entry_no_build_has_read_for_a_week_is_pruned_when_the_next_is_stored
    Dir.mktmpdir do |folder|
      cache = File.join(folder, "packs")
      FileUtils.mkdir_p(cache)
      old = File.join(cache, "old#{VBlank::Original::PackCache::ENTRY_EXTENSION}")
      File.binwrite(old, Marshal.dump({}))
      eight_days_ago = Time.now - (8 * 86_400)
      File.utime(eight_days_ago, eight_days_ago, old)

      picture(cached_game(folder, cache))

      refute File.exist?(old)
      assert_equal 1, kept_entries(cache).size
    end
  end

  # Builds on threads of one process that miss together each store the bytes they made, and none
  # takes the half-written entry of another from under it. Each thread waits for every other to
  # have missed before it stores, so they store together; the race is tried for several copies,
  # each a key of its own, since one try can pass by luck.
  def test_builds_on_threads_that_miss_together_keep_one_entry_and_say_nothing
    Dir.mktmpdir do |folder|
      cache = VBlank::Original::PackCache.new(folder)
      program = halting_program
      said = warnings_from do
        COPIES_TRIED.times { |copy| store_on_threads_at_once(cache, UnpackingOfCopy.new(program: program, copy_bytes: "copy-#{copy}")) }
      end

      assert_empty said
      assert_equal COPIES_TRIED, Dir.glob(File.join(folder, "*")).size, "one entry for each copy, and nothing half-written"
    end
  end

  COPIES_TRIED = 10
  THREADS_STORING = 8

  # What the cache asks of an unpacking: its program and the copy it reads.
  UnpackingOfCopy = Data.define(:program, :copy_bytes)

  # THREADS_STORING builds of one copy on threads, every one missing before any stores.
  private def store_on_threads_at_once(cache, unpacking)
    missed = Queue.new
    go = Queue.new
    threads = Array.new(THREADS_STORING) do
      Thread.new do
        cache.slot_bytes(unpacking) do
          missed << true
          go.pop
          { walls: "\1".b * 65_536 }
        end
      end
    end
    THREADS_STORING.times { missed.pop }
    THREADS_STORING.times { go << true }
    threads.each(&:join)
  end

  # What the block warns. Minitest's capture_io takes a lock no test in a Ractor can read, and
  # $stderr is this Ractor's own, so it is swapped here, for the block's threads too.
  private def warnings_from
    said = StringIO.new
    before = $stderr
    $stderr = said
    yield
    said.string
  ensure
    $stderr = before
  end

  private def halting_program
    builder = VBlank::Builder.new
    builder.halt
    builder.finalize_program
    builder.program
  end

  def test_a_build_with_no_cache_keeps_nothing
    Dir.mktmpdir do |folder|
      picture(game_program(->(builder) { unpacked_pack(builder, folder).then { |pack| [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:heights])] } }))

      assert_empty Dir.glob(File.join(folder, "**", "*.pack"))
    end
  end
end
