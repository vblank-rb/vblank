# frozen_string_literal: true

require "test_helper"

# A CARTRIDGE LAID OUT THE HIROM WAY, made from one VBlank built the LoROM way, standing in for
# the retail cartridges (about half the console's library) that a game rebuilding one plays
# beside itself.
#
# A LoROM cartridge is seen by the processor in 32K banks: bank k of the file at $k:8000-$k:FFFF.
# A HiROM one is seen in 64K banks, and the top half of each, $k:8000-$k:FFFF for banks $00-$3F
# and their copies at $80 and up, is the file from k*$10000 + $8000. So each LoROM bank put there
# is seen at the address it was built for, and the header that was at $7FC0 of the file lands at
# $FFC0, where a HiROM cartridge keeps it. What is left is to say HiROM in its map mode, keeping
# the fast bit, to say the new size, and to add the bytes up again. The file's bottom halves are
# filler, so nothing is at $7FC0 that reads as a header.
module HiROMLayout
  HIROM_HEADER_AT = 0xFFC0
  HIROM_MAP_MODE_AT = 0xFFD5
  HIROM_ROM_SIZE_AT = 0xFFD7
  HIROM_COMPLEMENT_AT = 0xFFDC
  HIROM = 0x01 # the map mode's low bit: HiROM, not LoROM

  private def hirom_layout_of(lorom)
    banks = lorom.bytes.bytesize / 0x8000
    hirom = ("\xFF".b * 0x8000 * 2 * banks)
    banks.times { |k| hirom[(k * 0x10000) + 0x8000, 0x8000] = lorom.bytes.byteslice(k * 0x8000, 0x8000) }
    hirom.setbyte(HIROM_MAP_MODE_AT, hirom.getbyte(HIROM_MAP_MODE_AT) | HIROM)
    hirom.setbyte(HIROM_ROM_SIZE_AT, VBlank::Cartridge::SNESROM.size_byte(hirom.bytesize))
    hirom[HIROM_COMPLEMENT_AT, 4] = [0xFFFF, 0x0000].pack("v2")
    sum = hirom.sum(16)
    hirom[HIROM_COMPLEMENT_AT, 4] = [sum ^ 0xFFFF, sum].pack("v2")
    hirom
  end
end

# The Super Nintendo cartridge's header and checksum, checked against the layout every cartridge
# of the console carries (fullsnes, "SNES Cartridge ROM Header"): the header at $FFC0 of the first
# bank — offset $7FC0 of a LoROM file — and the vectors after it.
class TestSNESROM < Minitest::Test
  include HiROMLayout

  SNESROM = VBlank::Cartridge::SNESROM

  private def rom(size: 100, **options)
    SNESROM.new(["\xEA".b * size], title: "Pong", vectors: { reset: 0x8000, nmi: 0x8010 }, **options)
  end

  private def word_at(bytes, at) = bytes.byteslice(at, 2).unpack1("v")

  def test_the_header_says_a_fast_lorom_cartridge_for_north_america
    bytes = rom.bytes
    assert_equal "PONG".ljust(21, " "), bytes.byteslice(0x7FC0, 21)
    assert_equal 0x30, bytes.getbyte(0x7FD5), "map mode: LoROM, fast"
    assert_equal 0x00, bytes.getbyte(0x7FD6), "cartridge type: ROM alone"
    assert_equal 0x05, bytes.getbyte(0x7FD7), "32K is 2^5 kilobytes"
    assert_equal 0x00, bytes.getbyte(0x7FD8), "no RAM"
    assert_equal 0x01, bytes.getbyte(0x7FD9), "North America"
  end

  def test_a_save_has_battery_backed_ram
    bytes = rom(save_bytes: 0x2000).bytes
    assert_equal 0x02, bytes.getbyte(0x7FD6), "ROM, RAM and battery"
    assert_equal 0x03, bytes.getbyte(0x7FD8), "8K is 2^3 kilobytes"
  end

  def test_the_vectors_point_where_they_were_told
    bytes = rom.bytes
    assert_equal 0x8000, word_at(bytes, 0x7FFC), "reset"
    assert_equal 0x8010, word_at(bytes, 0x7FEA), "the native vertical blank interrupt"
  end

  def test_the_checksum_is_every_byte_added_and_its_complement_beside_it
    bytes = rom.bytes
    checksum = word_at(bytes, 0x7FDE)
    complement = word_at(bytes, 0x7FDC)
    assert_equal 0xFFFF, checksum ^ complement
    assert_equal checksum, bytes.sum(16)
  end

  def test_a_cartridge_is_a_power_of_two_in_size
    assert_equal 0x8000, rom.size
    big = SNESROM.new(["\xEA".b * 0x8000] * 3, title: "BIG", vectors: { reset: 0x8000 })
    assert_equal 0x20000, big.size
    assert_equal 0x07, big.bytes.getbyte(0x7FD7), "128K is 2^7 kilobytes"
  end

  def test_a_cartridge_says_whose_it_is
    assert_equal :snes, rom.console
    assert SNESROM.header?(rom.bytes)
    refute SNESROM.header?("\0".b * 0x8000)
    assert_equal "Pong".upcase, rom.title
  end

  # A CARTRIDGE FILE LAID OUT THE HIROM WAY is one too, its header found at $FFC0 of the file,
  # and its title read from there. Its map mode keeps the fast bit the LoROM one had.
  def test_a_hirom_file_is_a_cartridge_and_its_title_is_read_where_it_is
    hirom = hirom_layout_of(rom)

    assert_equal 0x31, hirom.getbyte(HIROM_MAP_MODE_AT), "map mode: HiROM, fast"
    assert SNESROM.header?(hirom)
    assert_equal "PONG".ljust(21, " "), SNESROM.title_field_of(hirom)
  end

  # A file is a cartridge only where its map mode says the layout its header was found in: a
  # LoROM map mode with good checksums at the HiROM place is neither, and so is a HiROM one at
  # the LoROM place.
  def test_a_header_whose_map_mode_names_the_other_layout_is_no_cartridge
    lorom_at_the_hirom_place = hirom_layout_of(rom).tap { |bytes| bytes.setbyte(HIROM_MAP_MODE_AT, 0x30) }
    hirom_at_the_lorom_place = rom.bytes.dup.tap { |bytes| bytes.setbyte(0x7FD5, 0x31) }

    refute SNESROM.header?(lorom_at_the_hirom_place)
    refute SNESROM.header?(hirom_at_the_lorom_place)
    refute SNESROM.header?("\0".b * 0x10000)
  end
end
