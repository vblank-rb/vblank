# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "made_up_original"
VBlank.require_game_file "../../../plain_ruby_game_parts"

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

  # A GAME'S OWN TEST asks for the slots (PackCache#slot_bytes) rather than a pack file, and is
  # cached a part at a time as a build is: the block plays the Unpacking it is handed, the parts
  # named, and a part changed between two calls is the only one played the second time.
  def test_slot_bytes_of_a_routine_in_parts_plays_only_a_changed_part
    Dir.mktmpdir do |folder|
      cache = PackCache.new(File.join(folder, "packs"))
      played = []
      slots_of = lambda do |unpacking, parts|
        cache.slot_bytes(unpacking, parts: parts) do |playing, names|
          played << names
          playing.slot_bytes_in(playing.run_fastest)
        end
      end
      slots_of.call(*routine_in_parts(folder))
      unpacking, parts = routine_in_parts(folder, changed: %i[heights])
      second = slots_of.call(unpacking, parts)

      assert_equal [%i[walls heights sums], %i[heights]], played
      assert_equal Pack.from_bytes(whole_routine_pack(unpacking)).slots, second, "the slots are the whole routine's"
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

  # NAMES VBLANK MAKES FOR A PART carry nothing between parts: the console the build is for, named
  # by every part's program, and the names the build makes unique, each part built alone making
  # the same ones: the hidden copy of a value picked between two, and the game variable of an
  # object's instance variable (TickerPart, test/plain_ruby_game_parts.rb), which the whole routine
  # names apart (`ticker_part_ticks_2`). Parts sharing only those need nothing of each other, while
  # a part reading a variable an earlier part set still needs that part.
  private def parts_with_locals(folder)
    builder = VBlank::Builder.new(options: VBlank::Cartridge::Options.new(console: :gba))
    builder.data_pack(from: original(folder), version: "1") do |slots|
      slots.numbers :first, count: 2, width: :byte, signed: false
      slots.numbers :second, count: 2, width: :byte, signed: false
      slots.numbers :third, count: 1, width: :byte, signed: false
      slots.fill_from_copy(:first) do |copy, into|
        low = copy.byte(0)
        high = low > 3 ? copy.byte(1) : copy.byte(2)
        into[:first][0] = low
        into[:first][1] = high
        var(:carried, 0).store!(copy.byte(3))
        TickerPart.new(self, :first_tick)
        call :first_tick
      end
      slots.fill_from_copy(:second) do |copy, into|
        low = copy.byte(4)
        high = low > 3 ? copy.byte(5) : copy.byte(6)
        into[:second][0] = low
        into[:second][1] = high
        TickerPart.new(self, :second_tick)
        call :second_tick
      end
      slots.fill_from_copy(:third) { |copy, into| into[:third][0] = copy.byte(7) + var(:carried, 0) }
    end.unpacking_parts
  end

  def test_parts_sharing_only_names_vblank_made_need_nothing_of_each_other
    Dir.mktmpdir do |folder|
      parts = parts_with_locals(folder)

      assert_empty parts.inputs_of(:second)
      assert_equal %i[second], parts.played_for(%i[second])
    end
  end

  def test_a_part_reading_a_variable_an_earlier_part_set_still_needs_it
    Dir.mktmpdir { |folder| assert_equal %i[first], parts_with_locals(folder).inputs_of(:third) }
  end

  # ONE OBJECT REACHED FROM TWO PARTS hands a number from one to the other through its instance
  # variable's game variable (LampPart, test/plain_ruby_game_parts.rb), which no slot shows. Built
  # alone, the part reading it reaches the variable the other part's build made, and a change to
  # the writing part would leave the reader's cached slots stale: the build refuses, naming both.
  def test_a_part_reading_an_object_another_part_made_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(VBlank::Original::OutsideVariableError) do
        VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :switch, count: 1, width: :byte, signed: false
          slots.numbers :shown, count: 1, width: :byte, signed: false
          lamp = nil
          slots.fill_from_copy(:switch) do |copy, into|
            into[:switch][0] = copy.byte(0)
            lamp = LampPart.new
            repeat(1) { lamp.lit = copy.byte(1) }
          end
          slots.fill_from_copy(:shown) { |_copy, into| into[:shown][0] = lamp.lit }
        end.unpacking_parts
      end

      assert_match(/Part :shown .* part :switch made it.*write it into a slot/m, error.message)
    end
  end

  # An object the game made before its data pack keeps a variable of the game's own build, which
  # the unpacking, a program of its own, never declares: it would read nothing there.
  def test_an_unpacking_reading_an_object_made_outside_it_is_refused
    Dir.mktmpdir do |folder|
      builder = VBlank::Builder.new
      lamp = LampPart.new
      error = assert_raises(VBlank::Original::OutsideVariableError) do
        builder.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :shown, count: 1, width: :byte, signed: false
          slots.fill_from_copy { |_copy, into| into[:shown][0] = lamp.lit }
        end
      end

      assert_match(/:lamp_part_lit.*outside the unpacking.*inside the `slots.fill_from_copy` block/m, error.message)
    end
  end

  # TWO PARTS, EACH ASKING FOR STEPS FROM A RUBY LOOP, each made into a table loop
  # (Original::StepTables). Built alone, a part makes the same tables as after the part before it,
  # so it is no part built apart, and the pack put together from the parts is the whole routine's.
  COPIES_A_PART = 4

  def test_parts_whose_steps_are_made_into_table_loops_build_alike_alone
    Dir.mktmpdir do |folder|
      pack = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :first, count: COPIES_A_PART, width: :byte, signed: false
        slots.numbers :second, count: COPIES_A_PART, width: :byte, signed: false
        slots.fill_from_copy :first do |copy, into|
          COPIES_A_PART.times { |n| copy.copy_bytes at: SPEEDS_AT + n, count: 1, into: into[:first], start: n }
        end
        slots.fill_from_copy :second do |copy, into|
          COPIES_A_PART.times { |n| copy.copy_bytes at: TILES_AT + (n * 3), count: 1, into: into[:second], start: n }
        end
      end
      cache = PackCache.new(File.join(folder, "packs"))
      made, = cached_pack(cache, pack.unpacking, pack.unpacking_parts)

      assert_equal whole_routine_pack(pack.unpacking), made.to_bytes
    end
  end

  # RUBY STATE ONE PART'S BLOCK LEAVES FOR ANOTHER, which no program shows. Here the first part
  # sets an instance variable as it is built, and the second reads it to choose where it reads the
  # copy. Built alone, the second part reads somewhere else, so its cache entry would be keyed on
  # a part that is not the one the whole routine plays: a change to the first part's number would
  # leave the second part's slot stale. The build refuses, naming the second part.
  def test_a_part_built_from_ruby_another_part_left_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(VBlank::Original::PartBuiltApartError) do
        VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :first, count: 1, width: :byte, signed: false
          slots.numbers :second, count: 1, width: :byte, signed: false
          slots.fill_from_copy(:first) do |copy, into|
            @second_at = 3
            into[:first][0] = copy.byte(0)
          end
          slots.fill_from_copy(:second) { |copy, into| into[:second][0] = copy.byte(@second_at || 1) }
        end.unpacking_parts
      end

      assert_match(/Part :second .*another way when it is made alone.*slot/m, error.message)
    end
  end

  # A LOCAL BOTH PARTS' BLOCKS CLOSE OVER, which the first part sets as it is built and the second
  # reads. Each part built alone is built after the whole routine, so the second sees the number
  # the first set, and a change to that number changes the second part's key: the pack after the
  # change is the whole routine's, byte for byte.
  private def parts_sharing_a_local(folder, at:)
    VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
      slots.numbers :first, count: 1, width: :byte, signed: false
      slots.numbers :second, count: 1, width: :byte, signed: false
      shared = {}
      slots.fill_from_copy(:first) do |copy, into|
        shared[:at] = at
        into[:first][0] = copy.byte(0)
      end
      slots.fill_from_copy(:second) { |copy, into| into[:second][0] = copy.byte(shared.fetch(:at)) }
    end.then { |pack| [pack.unpacking, pack.unpacking_parts] }
  end

  def test_parts_sharing_a_local_make_the_whole_routines_pack_after_a_change
    Dir.mktmpdir do |folder|
      cache = PackCache.new(File.join(folder, "packs"))
      cached_pack(cache, *parts_sharing_a_local(folder, at: SPEEDS_AT))
      unpacking, parts = parts_sharing_a_local(folder, at: SPEEDS_AT + 1)
      made, = cached_pack(cache, unpacking, parts)

      assert_equal whole_routine_pack(unpacking), made.to_bytes
    end
  end

  # THE COUNT OF BYTES DONE runs on from one part to the next, so a later part reading it reads
  # what the parts before it wrote, which a part played alone does not. The build refuses it in
  # every part but the first.
  def test_a_later_part_reading_the_bytes_done_is_refused
    Dir.mktmpdir do |folder|
      error = assert_raises(ArgumentError) do
        VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :first, count: 4, width: :byte, signed: false
          slots.numbers :second, count: 1, width: :byte, signed: false
          slots.fill_from_copy(:first) { |copy, into| copy.copy_bytes at: SPEEDS_AT, count: 4, into: into[:first] }
          slots.fill_from_copy(:second) { |copy, into| into[:second][0] = copy.bytes_done }
        end
      end

      assert_match(/Part :second .*bytes_done/m, error.message)
    end
  end

  def test_the_first_part_may_read_the_bytes_done
    Dir.mktmpdir do |folder|
      parts = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
        slots.numbers :first, count: 4, width: :byte, signed: false
        slots.numbers :second, count: 1, width: :byte, signed: false
        slots.fill_from_copy(:first) do |copy, into|
          copy.copy_bytes at: SPEEDS_AT, count: 3, into: into[:first]
          into[:first][3] = copy.bytes_done
        end
        slots.fill_from_copy(:second) { |copy, into| into[:second][0] = copy.byte(0) }
      end.unpacking_parts

      assert_equal %i[first second], parts.names
    end
  end

  # EVERY WAY A PART WRITES A SLOT tells the cache it wrote it, so a part reading that slot is
  # played with the part that wrote it. One block a verb, each writing the slot :written.
  WRITES_BY_VERB = {
    byte: ->(copy, into) { into[:written][0] = copy.byte(0) },
    half: ->(copy, into) { into[:halves][0] = copy.half(0) },
    cell: ->(copy, into) { into[:cells].write_cell(0, tile: copy.byte(0)) },
    color: ->(copy, into) { into[:colors].write_color(0, red: copy.byte(0), green: 0, blue: 0) },
    copy_bytes: ->(copy, into) { copy.copy_bytes at: 0, count: 2, into: into[:written] },
    unpack: ->(copy, into) { copy.unpack_lz77 at: LZ77_AT, into: into[:walls] }
  }.freeze
  SLOT_WRITTEN_BY = { byte: :written, half: :halves, cell: :cells, color: :colors, copy_bytes: :written, unpack: :walls }.freeze

  def test_every_verb_that_writes_a_slot_makes_its_reader_need_the_writer
    WRITES_BY_VERB.each do |verb, write|
      read = SLOT_WRITTEN_BY.fetch(verb)
      Dir.mktmpdir do |folder|
        parts = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
          slots.numbers :written, count: 2, width: :byte, signed: false
          slots.numbers :halves, count: 1, width: :half, signed: false
          slots.map_cells :cells, count: 1
          slots.colors :colors, count: 1
          slots.tiles :walls, count: 2
          slots.numbers :read, count: 1, width: :byte, signed: false
          slots.fill_from_copy(:writer) { |copy, into| write.call(copy, into) }
          slots.fill_from_copy(:reader) { |_copy, into| into[:read][0] = into[read][0] }
        end.unpacking_parts

        assert_equal %i[writer], parts.inputs_of(:reader), "the reader of a slot written by #{verb}"
      end
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

  # A ROUTINE OF ONE BLOCK IS BUILT ONCE in a build with a cache, through to the pack file, and the
  # pack's handle hands a game's test that same unpacking rather than building it again.
  def test_a_routine_of_one_block_is_built_once
    Dir.mktmpdir do |folder|
      built = 0
      builder = VBlank::Builder.new
      pack = builder.data_pack(from: original(folder), version: "1", cache: File.join(folder, "packs")) do |slots|
        slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
        slots.fill_from_copy do |copy, into|
          built += 1
          copy.unpack_rle at: RLE_AT, into: into[:heights]
        end
      end
      builder.finalize_program
      builder.made_data_pack_file
      pack.unpacking

      assert_equal 1, built
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
