# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# The data pack (Original::Pack): the one file a port reads the original's data from, made from the
# player's copy. It starts with the format it is written in, the SHA-1 of the copy it was made from
# and the version of the build that made it, so a later build can tell a pack it can read from one
# it must make again.
class TestOriginalPack < Minitest::Test
  COPY = (0...64).map { |at| (at * 7) & 0xFF }.pack("C*").freeze
  SHA1 = Digest::SHA1.hexdigest(COPY)

  private def slots
    [VBlank::Original::Slot.colors(:palette, at: 0, count: 4),
     VBlank::Original::Slot.tiles(:walls, at: 8, count: 1),
     VBlank::Original::Slot.numbers(:speeds, at: 40, count: 3, width: :half, signed: false)]
  end

  private def made = VBlank::Original::Pack.made_from(COPY, sha1: SHA1, build_version: "1.2", slots: slots)

  def test_each_slot_holds_the_bytes_of_the_copy_it_was_cut_from
    pack = made

    assert_equal COPY.byteslice(0, 8), pack.bytes_of(:palette)
    assert_equal COPY.byteslice(8, 32), pack.bytes_of(:walls)
    assert_equal COPY.byteslice(40, 6), pack.bytes_of(:speeds)
  end

  def test_the_file_starts_with_its_format_the_copys_hash_and_the_builds_version
    bytes = made.to_bytes

    assert_equal "VBLANKPK", bytes.byteslice(0, 8)
    assert_equal VBlank::Original::Pack::FORMAT_VERSION, bytes.byteslice(8, 2).unpack1("v")
    assert_equal SHA1, bytes.byteslice(10, 20).unpack1("H*")
    assert_equal "1.2", bytes.byteslice(31, bytes.getbyte(30))
  end

  def test_a_pack_read_back_from_its_file_is_the_pack_that_was_written
    Dir.mktmpdir do |folder|
      path = File.join(folder, "game.pack")
      made.write(path)
      read = VBlank::Original::Pack.read(path)

      assert_equal made, read
      assert_equal SHA1, read.rom_sha1
      assert_equal "1.2", read.build_version
    end
  end

  def test_a_file_that_is_not_a_pack_is_refused
    refused = assert_raises(VBlank::Original::WrongPack) { VBlank::Original::Pack.from_bytes("not a pack at all") }

    assert_match "not a data pack", refused.message
  end

  def test_a_pack_in_a_format_this_build_does_not_know_is_refused
    bytes = made.to_bytes.dup
    bytes[8, 2] = [VBlank::Original::Pack::FORMAT_VERSION + 1].pack("v")
    refused = assert_raises(VBlank::Original::WrongPack) { VBlank::Original::Pack.from_bytes(bytes) }

    assert_match "format", refused.message
  end

  def test_a_pack_cut_short_is_refused
    bytes = made.to_bytes
    refused = assert_raises(VBlank::Original::WrongPack) { VBlank::Original::Pack.from_bytes(bytes.byteslice(0, bytes.bytesize - 3)) }

    assert_match "cut short", refused.message
  end

  # A pack that exists can always be written: what its file cannot hold is refused as it is made.
  def test_a_build_version_too_long_for_the_file_is_refused
    refused = assert_raises(ArgumentError) do
      VBlank::Original::Pack.made_from(COPY, sha1: SHA1, build_version: "1" * 256, slots: slots)
    end

    assert_match "1 to 255 bytes", refused.message
  end

  def test_a_slot_name_too_long_for_the_file_is_refused
    long = VBlank::Original::Slot.colors(:"#{'a' * 256}", at: 0, count: 1)
    refused = assert_raises(ArgumentError) do
      VBlank::Original::Pack.made_from(COPY, sha1: SHA1, build_version: "1", slots: [long])
    end

    assert_match "slot name", refused.message
  end

  def test_a_sha1_that_is_not_forty_hex_digits_is_refused
    refused = assert_raises(ArgumentError) do
      VBlank::Original::Pack.made_from(COPY, sha1: "abc", build_version: "1", slots: slots)
    end

    assert_match "40 hex digits", refused.message
  end

  def test_a_sha1_in_capitals_is_kept_and_read_back_in_lower_case
    pack = VBlank::Original::Pack.made_from(COPY, sha1: SHA1.upcase, build_version: "1", slots: slots)

    assert_equal SHA1, pack.rom_sha1
    assert_equal SHA1, VBlank::Original::Pack.from_bytes(pack.to_bytes).rom_sha1
  end
end
