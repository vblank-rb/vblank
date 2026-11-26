# frozen_string_literal: true

require "test_helper"
require "digest"
require "tmpdir"

# The disc a PlayStation game with data to read as it runs is built as (Cartridge::PS1Disc): Mode 2
# Form 1 sectors with their checks (Cartridge::CDSector), an ISO 9660 file system the BIOS boots from,
# and the program's data at the sector the program reads it from. Read back here as the emulator's
# gem reads a disc (RubyPS1Emulator::DiscProgram), and booted in Beetle PSX by the table groups' test.
class TestPS1Disc < Minitest::Test
  Disc = VBlank::Cartridge::PS1Disc
  Sector = VBlank::Cartridge::CDSector

  private def program(code_bytes, load_at: 0x8001_0000)
    header = "\0".b * 0x800
    header[0, 8] = "PS-X EXE"
    header[0x18, 8] = [load_at, code_bytes].pack("VV")
    header + ("\0".b * code_bytes)
  end

  # Sector 16 holding "PLAYSTATION", whose EDC and parity Beetle PSX's own check of a sector
  # (edc_lec_check_and_correct, which the drive runs on each data sector it reads) passes, and from
  # which it mends two damaged bytes of the data: so the parity is right as well as the EDC.
  CHECKED_SECTOR_SHA256 = "b9af7451eb289a0c153508ef5bc2387fd6b87d19ecc9717f4db7794d92ef41d0"

  def test_a_sector_carries_the_checks_the_drive_reads_it_with
    sector = Sector.encode(16, "PLAYSTATION")

    assert_equal 2352, sector.bytesize
    assert_equal Sector::SYNC, sector.byteslice(0, 12)
    assert_equal [0x00, 0x02, 0x16, 0x02], sector.byteslice(12, 4).bytes, "16 sectors after two seconds, in BCD, mode 2"
    assert_equal CHECKED_SECTOR_SHA256, Digest::SHA256.hexdigest(sector)
  end

  def test_the_bios_finds_the_program_and_the_data_is_where_the_program_reads_it
    data = Random.new(7).bytes(5000)
    disc = Disc.new(program: program(0x1000), data: data, title: "Levels!", stack: 0x801F_FFF0)
    Dir.mktmpdir do |dir|
      cue = File.join(dir, "game.cue")
      disc.write(cue)
      VBlank::Diagnostics::Emulator.load_ps1!

      assert_equal 0x8001_0000...0x8001_1000, RubyPS1Emulator::DiscProgram.code_of(cue)
      image = File.binread(File.join(dir, "game.bin"))
      read = Array.new(3) { |i| image.byteslice(((Disc::DATA_AT + i) * Sector::RAW) + 24, Disc::SECTOR) }.join

      assert_equal data, read.byteslice(0, data.bytesize)
      assert_equal disc.sector_count * Sector::RAW, image.bytesize
    end
  end

  # Beetle PSX, as a console's drive, reads data only from a disc it takes for a PlayStation disc: one
  # whose program has a product code's name. The name is a made-up code, and no Sony text is written.
  def test_the_program_is_named_as_a_product_code_and_no_licence_text_is_written
    disc = Disc.new(program: program(0x800), data: "x", title: "GAME", stack: 0x801F_FFF0)

    assert_match(/\AS[CL][EUP]S_\d{3}\.\d{2}\z/, Disc::PROGRAM_NAME)
    refute_includes disc.image, "Licensed"
    refute_includes disc.image, "Sony"
  end
end
