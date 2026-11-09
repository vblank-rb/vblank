# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"
require "folder_original"

# AN ORIGINAL WHOSE RELEASE IS SEVERAL FILES (Original::Release#files): its copy is the folder that
# holds them, found and checked file by file (Original::Game#copy), and a data pack made from it
# reads each file through copy.file. The answer key is FolderOriginal's fixture, whose pieces are
# MadeUpOriginal's colours, tiles and heights.
class TestFolderCopy < Minitest::Test
  include FolderOriginal

  def test_the_folder_is_accepted_as_its_release_reading_only_the_files_it_names
    copy = folder_original.copy

    assert_equal "MU1", copy.release
    assert_equal %w[INDEX.MU1 data.mu1], copy.files.map { |file| File.basename(file.path) }
    assert_equal 18 + 154, copy.read_bytes.bytesize
  end

  def test_the_all_in_one_pack_holds_each_piece_found_through_the_index_file
    pack = VBlank::Original::Pack.from_bytes(folder_port(folder_original).data_pack_file)

    assert_equal PALETTE.pack("v*"), pack.bytes_of(:palette)
    assert_equal TILE_BYTES, pack.bytes_of(:walls)
    assert_equal HEIGHTS.pack("C*"), pack.bytes_of(:heights)
  end

  # The header holds the SHA-1 of the release's list of files, which a build with no copy works out
  # the same.
  def test_the_pack_names_the_release_by_the_sha1_of_its_list_of_files
    listed = RELEASES.fetch("MU1").fetch("files").map { |name, file| "#{name} #{file['size']} #{file['sha1']}\n" }.join
    pack = VBlank::Original::Pack.from_bytes(folder_port(folder_original).data_pack_file)

    assert_equal Digest::SHA1.hexdigest(listed), pack.rom_sha1
  end

  def test_a_file_the_release_does_not_name_changes_nothing
    Dir.mktmpdir do |dir|
      copy = fixture_copy_in(dir)
      File.write(File.join(copy, "CONFIG.MU1"), "volume=2\nmusic=off\n")
      File.write(File.join(copy, "SAVEGAM0.MU1"), "a save")

      assert_equal folder_port(folder_original).data_pack_file, folder_port(folder_original(copy)).data_pack_file
    end
  end

  def test_a_folder_without_a_file_of_the_release_is_refused_naming_it
    Dir.mktmpdir do |dir|
      copy = fixture_copy_in(dir)
      File.delete(File.join(copy, "data.mu1"))
      refused = assert_raises(VBlank::Original::WrongCopy) { folder_original(copy).copy }

      assert_match "lacks DATA.MU1", refused.message
    end
  end

  def test_a_changed_file_is_refused_naming_it_and_its_sha1
    Dir.mktmpdir do |dir|
      copy = fixture_copy_in(dir)
      File.binwrite(File.join(copy, "data.mu1"), File.binread(File.join(copy, "data.mu1")).reverse)
      refused = assert_raises(VBlank::Original::WrongCopy) { folder_original(copy).copy }

      assert_match "DATA.MU1 is not the file of the MU1 release", refused.message
      assert_match "14687c66a75899e0d39ad00b230306d0d287ad3b", refused.message
    end
  end

  def test_a_file_of_a_release_listed_without_its_sha1_is_refused
    refused = assert_raises(ArgumentError) do
      VBlank::Original::Release.from("MU1", "files" => { "INDEX.MU1" => { "size" => 18 } })
    end

    assert_match "needs its sha1", refused.message
  end

  def test_a_routine_that_reads_a_file_the_release_does_not_hold_is_refused_naming_the_files_it_holds
    refused = assert_raises(ArgumentError) do
      VBlank::Builder.new.data_pack(from: folder_original, version: "1") do |slots|
        slots.numbers :one, count: 1, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.file("MAPS.MU1").copy_bytes at: 0, count: 1, into: pack[:one] }
      end
    end

    assert_match "holds no file MAPS.MU1", refused.message
    assert_match "INDEX.MU1, DATA.MU1", refused.message
  end

  def test_a_read_written_past_the_end_of_a_file_is_refused
    refused = assert_raises(ArgumentError) do
      VBlank::Builder.new.data_pack(from: folder_original, version: "1") do |slots|
        slots.numbers :one, count: 4, width: :byte, signed: false
        slots.fill_from_copy { |copy, pack| copy.file("INDEX.MU1").copy_bytes at: 16, count: 4, into: pack[:one] }
      end
    end

    assert_match "INDEX.MU1 holds bytes 0 to 17", refused.message
  end
end
