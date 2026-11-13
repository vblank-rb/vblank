# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "made_up_original"

# A ROUTINE IN PARTS IS CACHED A PART AT A TIME. A port's unpacking given as named parts
# (`slots.fill_from_copy :music do ... end`) keeps each part's slots apart in the pack cache, so a
# change to one part plays that part again, with the parts that read what it wrote, and takes the
# rest from the cache. The answer key is the whole routine played on the interpreter: the pack
# put together from the parts is that pack, byte for byte.
class TestPackCacheParts < Minitest::Test
  include MadeUpOriginal

  PackCache = VBlank::Original::PackCache
  Pack = VBlank::Original::Pack

  # Three parts: the walls and the heights, each unpacked from the copy and needing nothing of the
  # other, and the sums, worked out from the walls the first part wrote. +changed+ names the parts
  # written another way, each still writing its own slots.
  private def routine_in_parts(folder, changed: [])
    builder = VBlank::Builder.new
    pack = builder.data_pack(from: original(folder), version: "1") do |slots|
      slots.colors :palette, at: PALETTE_AT, count: 16
      slots.tiles :walls, count: 2
      slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
      slots.numbers :sums, count: 8, width: :byte, signed: false
      slots.fill_from_copy :walls do |copy, into|
        copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
        into[:walls][0] = 0x55 if changed.include?(:walls)
      end
      slots.fill_from_copy :heights do |copy, into|
        copy.unpack_rle at: RLE_AT, into: into[:heights]
        into[:heights][0] = 99 if changed.include?(:heights)
      end
      slots.fill_from_copy :sums do |_copy, into|
        added = changed.include?(:sums) ? 2 : 1
        repeat(8) { |i| into[:sums][i] = into[:walls][i] + added }
      end
    end
    [pack.unpacking, pack.unpacking_parts]
  end

  # The pack +cache+ makes of the routine, and the parts each play of it played, in order.
  private def cached_pack(cache, unpacking, parts)
    played = []
    made = cache.pack(unpacking, sha1: SHA1, build_version: "1", parts: parts) do |path, playing, names|
      played << names
      playing.write_pack_fastest(path, sha1: SHA1, build_version: "1")
    end
    [made, played]
  end

  # The pack file the whole routine writes, played on the interpreter.
  private def whole_routine_pack(unpacking)
    ran = unpacking.run_on(Reference.new, frames: unpacking.most_frames, max_steps: unpacking.most_steps_a_frame)
    unpacking.pack_file_in(ran, sha1: SHA1, build_version: "1")
  end

  # The parts played when the routine is cached once as it is, and then again with +changed+, and
  # whether the second pack is the whole routine's.
  private def parts_played_after_changing(changed)
    Dir.mktmpdir do |folder|
      cache = PackCache.new(File.join(folder, "packs"))
      first, first_played = cached_pack(cache, *routine_in_parts(folder))
      unpacking, parts = routine_in_parts(folder, changed: changed)
      second, second_played = cached_pack(cache, unpacking, parts)

      assert_equal [%i[walls heights sums]], first_played
      assert_equal whole_routine_pack(unpacking), second.to_bytes, "the pack is the whole routine's, byte for byte"
      refute_equal first.to_bytes, second.to_bytes, "the change is in the pack"
      second_played
    end
  end

  def test_a_routine_in_parts_cached_again_plays_nothing
    Dir.mktmpdir do |folder|
      cache = PackCache.new(File.join(folder, "packs"))
      unpacking, parts = routine_in_parts(folder)
      first, = cached_pack(cache, unpacking, parts)
      again, played = cached_pack(cache, *routine_in_parts(folder))

      assert_empty played
      assert_equal whole_routine_pack(unpacking), first.to_bytes
      assert_equal first.to_bytes, again.to_bytes
    end
  end

  def test_a_changed_part_nothing_reads_is_played_alone
    assert_equal [%i[heights]], parts_played_after_changing(%i[heights])
  end

  def test_a_changed_part_is_played_with_the_parts_that_read_it
    assert_equal [%i[walls sums]], parts_played_after_changing(%i[walls])
  end

  # The sums read the walls, so the walls are played again to hand them over, though their slots
  # are in the cache.
  def test_a_changed_part_is_played_with_the_parts_it_reads
    assert_equal [%i[walls sums]], parts_played_after_changing(%i[sums])
  end

  # A slot two parts write is kept in the later part's entry alone, since a run of both holds only
  # its bytes. A later part that stops writing it hands it back to the earlier part, which is
  # played again to keep it, and the pack holds the earlier part's bytes, as the whole routine does.
  private def overwritten_slot(folder, later_writes_shared:)
    VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
      slots.numbers :shared, count: 2, width: :byte, signed: false
      slots.numbers :other, count: 1, width: :byte, signed: false
      slots.fill_from_copy(:first) { |copy, into| copy.copy_bytes at: PALETTE_AT, count: 2, into: into[:shared] }
      slots.fill_from_copy(:later) do |copy, into|
        into[later_writes_shared ? :shared : :other][0] = copy.byte(SPEEDS_AT)
      end
    end.then { |pack| [pack.unpacking, pack.unpacking_parts] }
  end

  def test_a_later_part_that_stops_writing_a_slot_leaves_the_earlier_parts_bytes
    Dir.mktmpdir do |folder|
      cache = PackCache.new(File.join(folder, "packs"))
      cached_pack(cache, *overwritten_slot(folder, later_writes_shared: true))
      unpacking, parts = overwritten_slot(folder, later_writes_shared: false)
      made, played = cached_pack(cache, unpacking, parts)

      assert_equal [%i[first later]], played
      assert_equal whole_routine_pack(unpacking), made.to_bytes
    end
  end

  # Two parts naming one variable may hand a number from one to the other, which no slot shows,
  # so the later one is played with the earlier.
  def test_parts_naming_one_variable_are_played_together
    Dir.mktmpdir do |folder|
      parts = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :first, count: 1, width: :byte, signed: false
        slots.numbers :second, count: 1, width: :byte, signed: false
        slots.numbers :third, count: 1, width: :byte, signed: false
        slots.fill_from_copy(:first) { |copy, into| into[:first][0] = copy.byte(0) + var(:carried, 0) }
        slots.fill_from_copy(:second) { |copy, into| into[:second][0] = copy.byte(1) }
        slots.fill_from_copy(:third) { |copy, into| into[:third][0] = copy.byte(2) + var(:carried, 0) }
      end.unpacking_parts

      assert_equal %i[first], parts.inputs_of(:third)
      assert_empty parts.inputs_of(:second)
    end
  end

  # Built all-in-one with a cache, the routine in parts makes the pack the build with no cache makes.
  def test_a_build_with_a_cache_makes_the_pack_of_the_build_without
    Dir.mktmpdir do |folder|
      made = [nil, File.join(folder, "packs"), File.join(folder, "packs")].map do |cache|
        builder = VBlank::Builder.new
        builder.data_pack(from: original(folder), version: "1", cache: cache) do |slots|
          slots.tiles :walls, count: 2
          slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
          slots.fill_from_copy(:walls) { |copy, into| copy.unpack_lz77 at: LZ77_AT, into: into[:walls] }
          slots.fill_from_copy(:heights) { |copy, into| copy.unpack_rle at: RLE_AT, into: into[:heights] }
        end
        builder.made_data_pack_file
      end

      assert_equal [made.first] * 3, made
      assert_equal 2, Dir.glob(File.join(folder, "packs", "*.pack")).size, "an entry for each part"
    end
  end

  # A FIRST BUILD BUILDS EACH PART TWICE AT MOST: once in the whole routine, which it plays, and
  # once alone, to learn what it reads and writes. A part's key is made from those, so working out
  # the keys builds nothing more; a port's routine of many parts was otherwise built again for the
  # key of every part, which cost more than playing it.
  def test_a_first_build_with_a_cache_builds_each_part_twice_at_most
    Dir.mktmpdir do |folder|
      built = Hash.new(0)
      builder = VBlank::Builder.new
      builder.data_pack(from: original(folder), version: "1", cache: File.join(folder, "packs")) do |slots|
        slots.tiles :walls, count: 2
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.numbers :sums, count: 8, width: :byte, signed: false
        slots.fill_from_copy(:walls) do |copy, into|
          built[:walls] += 1
          copy.unpack_lz77 at: LZ77_AT, into: into[:walls]
        end
        slots.fill_from_copy(:heights) do |copy, into|
          built[:heights] += 1
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
        slots.fill_from_copy(:sums) do |_copy, into|
          built[:sums] += 1
          repeat(8) { |i| into[:sums][i] = into[:walls][i] + 1 }
        end
      end

      %i[walls heights sums].each { |part| assert_equal 2, built[part], "the times :#{part} was built" }
    end
  end

  # A part that calls a routine an earlier part defines cannot be built alone, so the routine is
  # cached whole, as a routine of one part is.
  def test_a_part_calling_a_routine_of_another_keeps_the_routine_whole
    Dir.mktmpdir do |folder|
      pack = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :first, count: 1, width: :byte, signed: false
        slots.numbers :second, count: 1, width: :byte, signed: false
        slots.fill_from_copy(:first) do |copy, into|
          func(:helper) { into[:first][0] = copy.byte(0) }
          call :helper
        end
        slots.fill_from_copy(:second) do |copy, into|
          call :helper
          into[:second][0] = copy.byte(1)
        end
      end

      assert_nil pack.unpacking_parts
    end
  end

  def test_a_routine_of_two_parts_names_each
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :first, count: 1, width: :byte, signed: false
          slots.fill_from_copy { |copy, into| into[:first][0] = copy.byte(0) }
          slots.fill_from_copy(:more) { |copy, into| into[:first][0] = copy.byte(1) }
        end
      end

      assert_match(/each part must have a name/, error.message)
    end
  end

  def test_a_part_named_twice_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :first, count: 1, width: :byte, signed: false
          slots.fill_from_copy(:music) { |copy, into| into[:first][0] = copy.byte(0) }
          slots.fill_from_copy(:music) { |copy, into| into[:first][0] = copy.byte(1) }
        end
      end

      assert_match(/:music of its routine twice/, error.message)
    end
  end
end
