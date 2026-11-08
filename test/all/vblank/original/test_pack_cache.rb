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

  def test_a_build_with_no_cache_keeps_nothing
    Dir.mktmpdir do |folder|
      picture(game_program(->(builder) { unpacked_pack(builder, folder).then { |pack| [pack[:palette], pack[:walls].tile(0), pack[:walls].tile(1), builder.table(:speeds, pack[:heights])] } }))

      assert_empty Dir.glob(File.join(folder, "**", "*.pack"))
    end
  end
end
