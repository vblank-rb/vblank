# frozen_string_literal: true

require "test_helper"

# The Genesis cartridge's header, vectors and checksum, checked against the layout every cartridge of
# the console carries (Sega's Genesis Software Manual; SGDK's src/boot/sega.s; Genesis Plus GX's
# core/loadrom.c): 64 vectors of four bytes from $0, a 256-byte header from $100, code from $200,
# and a checksum of every 16-bit word from $200.
class TestGenesisROM < Minitest::Test
  GenesisROM = VBlank::Cartridge::GenesisROM

  private def rom(size: 100, **options)
    GenesisROM.new("\x4E\x71".b * (size / 2),
                   title: "Pong", vectors: { reset: 0x200, vertical_interrupt: 0x240 }, **options)
  end

  private def long_at(bytes, at) = bytes.byteslice(at, 4).unpack1("N")
  private def word_at(bytes, at) = bytes.byteslice(at, 2).unpack1("n")

  def test_the_header_names_the_console_and_the_game
    bytes = rom.bytes
    assert_equal "SEGA MEGA DRIVE ", bytes.byteslice(0x100, 16)
    assert_equal "PONG".ljust(48, " "), bytes.byteslice(0x120, 48), "the domestic title"
    assert_equal "PONG".ljust(48, " "), bytes.byteslice(0x150, 48), "the overseas title"
    assert_equal "GM 00000000-00", bytes.byteslice(0x180, 14), "no serial a real game has"
    assert_equal "J", bytes.byteslice(0x190, 1), "a three-button pad"
    assert_equal "JUE", bytes.byteslice(0x1F0, 3), "every region"
  end

  def test_the_header_says_where_the_rom_and_the_ram_are
    bytes = rom.bytes
    assert_equal 0, long_at(bytes, 0x1A0)
    assert_equal bytes.bytesize - 1, long_at(bytes, 0x1A4)
    assert_equal 0xFF0000, long_at(bytes, 0x1A8)
    assert_equal 0xFFFFFF, long_at(bytes, 0x1AC)
  end

  def test_the_vectors_point_where_they_were_told
    bytes = rom.bytes
    assert_equal 0x200, long_at(bytes, 0x04), "reset"
    assert_equal 0x240, long_at(bytes, 0x78), "the vertical blank's interrupt"
    assert_equal 0x00FFFFFE, long_at(bytes, 0x00), "the stack starts at the top of work RAM"
  end

  def test_a_vector_not_named_points_where_reset_does
    assert_equal 0x200, long_at(rom.bytes, 0x70), "the horizontal interrupt"
    assert_equal 0x200, long_at(rom.bytes, 0x0C), "an address error"
  end

  def test_the_code_starts_where_the_header_ends
    assert_equal "\x4E\x71".b * 4, rom.bytes.byteslice(0x200, 8)
  end

  def test_the_checksum_is_every_word_from_the_start_of_the_code_added
    bytes = rom.bytes
    assert_equal bytes.byteslice(0x200..).unpack("n*").sum & 0xFFFF, word_at(bytes, 0x18E)
  end

  def test_a_cartridge_is_a_power_of_two_in_size_of_at_least_64k
    assert_equal 0x10000, rom.size
    assert_equal 0x20000, rom(size: 0x10000).size
  end

  def test_a_cartridge_says_whose_it_is
    assert_equal :genesis, rom.console
    assert GenesisROM.header?(rom.bytes)
    refute GenesisROM.header?("\0".b * 0x10000)
    assert_equal "PONG", rom.title
    assert_equal "PONG".ljust(48, " "), rom.header_title
  end

  def test_a_title_keeps_to_letters_digits_and_spaces
    cartridge = GenesisROM.new("\x4E\x71".b, title: "my-game, 2!", vectors: { reset: 0x200 })

    assert_equal "MY GAME  2", cartridge.title
  end
end
