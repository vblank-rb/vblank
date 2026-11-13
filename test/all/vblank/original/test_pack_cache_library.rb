# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "made_up_original"

# WHICH OF VBLANK'S OWN FILES A KEPT PACK IS KEYED ON. A pack is made by building the port's
# routine and playing it, so a change to the code that does either must make it again; a change
# to code that does neither (a console's lowering, the tests' own kit) must not, or every commit
# to VBlank replays a port's whole copy. The files are read from a library folder the test makes
# (PackLibrary's root), so no real library file is changed. The answer key for "what the play path
# reads" is test/interpreter/vblank/original/test_pack_library_left_out.rb.
class TestPackCacheLibrary < Minitest::Test
  include MadeUpOriginal

  PackCache = VBlank::Original::PackCache
  PackLibrary = VBlank::Original::PackLibrary

  # A file of the library a pack is never made with, and one it always is.
  LEFT_OUT_FILE = "vblank/ir/backends/gba/lowering.rb"
  PLAYED_FILE = "vblank/ir/backends/reference.rb"

  # A library folder of the two files, in +folder+.
  private def made_up_library(folder)
    root = File.join(folder, "lib")
    [LEFT_OUT_FILE, PLAYED_FILE].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), "# #{path}\n")
    end
    root
  end

  # Two parts, the walls and the heights, each unpacked from the copy.
  private def routine_in_parts(folder)
    pack = VBlank::Builder.new.data_pack(from: original(folder), version: "1") do |slots|
      slots.tiles :walls, count: 2
      slots.numbers :heights, count: HEIGHTS.length, width: :byte, signed: false
      slots.fill_from_copy(:walls) { |copy, into| copy.unpack_lz77 at: LZ77_AT, into: into[:walls] }
      slots.fill_from_copy(:heights) { |copy, into| copy.unpack_rle at: RLE_AT, into: into[:heights] }
    end
    [pack.unpacking, pack.unpacking_parts]
  end

  # The parts played when the routine is cached once, +change+ is run, and it is cached again.
  private def parts_played_again_after
    Dir.mktmpdir do |folder|
      library = made_up_library(folder)
      unpacking, parts = routine_in_parts(folder)
      played_with(folder, library, unpacking, parts)
      yield library
      played_with(folder, library, unpacking, parts)
    end
  end

  # The parts a fresh PackCache on +library+ plays to make the routine's pack.
  private def played_with(folder, library, unpacking, parts)
    played = []
    cache = PackCache.new(File.join(folder, "packs"), library: PackLibrary.new(root: library))
    cache.pack(unpacking, sha1: SHA1, build_version: "1", parts: parts) do |path, playing, names|
      played << names
      playing.write_pack_fastest(path, sha1: SHA1, build_version: "1")
    end
    played
  end

  def test_a_change_to_a_file_no_pack_is_made_with_leaves_every_part_hitting
    played = parts_played_again_after { |library| File.write(File.join(library, LEFT_OUT_FILE), "# changed\n") }

    assert_empty played
  end

  def test_a_change_to_a_file_a_pack_is_made_with_plays_every_part_again
    played = parts_played_again_after { |library| File.write(File.join(library, PLAYED_FILE), "# changed\n") }

    assert_equal [%i[walls heights]], played
  end

  def test_a_new_file_is_in_the_key_until_it_is_left_out
    played = parts_played_again_after { |library| File.write(File.join(library, "vblank/new_thing.rb"), "# new\n") }

    assert_equal [%i[walls heights]], played
  end
end
